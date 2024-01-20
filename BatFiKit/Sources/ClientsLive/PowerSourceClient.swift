//
//  PowerSourceClient+Live.swift
//
//
//  Created by Adam on 02/05/2023.
//

import AppShared
import Clients
import Dependencies
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os
import Shared

extension PowerSourceClient: DependencyKey {
    public static let liveValue: PowerSourceClient = {
        let logger = Logger(category: "⚡️")
        let observer = Observer(logger: logger)
        let getPowerSourceQueue = DispatchQueue.global(qos: .userInitiated)//(label: "software.micropixels.BatFi.PowerSourceClient")
        let getBatteryHealthQueue = DispatchQueue(label: "software.micropixels.BatFi.GetBatteryHealth")

        func getBatteryHealth() -> String? {
            let semaphore = DispatchSemaphore(value: 0)
            var outputData: Data?

            if Thread.isMainThread {
                logger.warning("getBatteryHealth() called on the main thread!")
            }

            getBatteryHealthQueue.async {

                if Thread.isMainThread {
                    logger.warning("Launching NSTask and waiting on the main thread!")
                }

                let task = Process()
                task.launchPath = "/usr/sbin/system_profiler"
                task.arguments = ["SPPowerDataType"]

                let pipe = Pipe()
                task.standardOutput = pipe
                task.launch()

                outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()

                semaphore.signal()
            }

            semaphore.wait()

            if let data = outputData, let output = String(data: data, encoding: .utf8) {
                let lines = output.split(separator: "\n")
                for line in lines {
                    if line.contains("Maximum Capacity") {
                        let components = line.components(separatedBy: ":")
                        if components.count == 2 {
                            let maximumCapacity = components[1].trimmingCharacters(in: .whitespaces)
                            return maximumCapacity
                        }
                        return nil
                    }
                }
            }

            return nil
        }

        func getPowerSourceInfo() throws -> PowerState {

            if Thread.isMainThread {
                logger.warning("getPowerSourceInfo() called on the main thread!")
            }

            func getValue<DataType>(_ identifier: String, from service: io_service_t) -> DataType? {
                if let valueRef = IORegistryEntryCreateCFProperty(service, identifier as CFString, kCFAllocatorDefault, 0) {
                    let value = valueRef.takeUnretainedValue() as? DataType
                    valueRef.release()
                    return value
                }

                return nil
            }

            let snapshotRef = IOPSCopyPowerSourcesInfo()
            defer { snapshotRef?.release() }
            let snapshot = snapshotRef?.takeUnretainedValue()
            let sourcesRef = IOPSCopyPowerSourcesList(snapshot)
            defer { sourcesRef?.release() }
            let sources = sourcesRef!.takeUnretainedValue() as Array
            let info = IOPSGetPowerSourceDescription(snapshot, sources[0]).takeUnretainedValue() as! [String: AnyObject]

            let batteryLevel = info[kIOPSCurrentCapacityKey] as? Int
            let isCharging = info[kIOPSIsChargingKey] as? Bool
            let powerSource = info[kIOPSPowerSourceStateKey] as? String
            let timeLeft = info[kIOPSTimeToEmptyKey] as? Int
            let timeToCharge = info[kIOPSTimeToFullChargeKey] as? Int
            let optimizedBatteryCharging = info["Optimized Battery Charging Engaged"] as? Bool

            guard
                let batteryLevel,
                let isCharging,
                let powerSource,
                let timeLeft,
                let timeToCharge,
                let optimizedBatteryCharging else {
                throw PowerSourceError.infoMissing
            }

            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            defer {
                IOServiceClose(service)
                IOObjectRelease(service)
            }

            guard let cycleCount: Int = getValue(kIOPMPSCycleCountKey, from: service) else {
                throw PowerSourceError.infoMissing
            }

            guard let temperature: Double = getValue(kIOPMPSBatteryTemperatureKey, from: service) else {
                throw PowerSourceError.infoMissing
            }
            let batteryTemperature = temperature / 100

            guard let chargerConnected: Bool = getValue(kIOPMPSExternalConnectedKey, from: service) else {
                throw PowerSourceError.infoMissing
            }

            let powerState = PowerState(
                batteryLevel: batteryLevel,
                isCharging: isCharging,
                powerSource: powerSource,
                timeLeft: timeLeft,
                timeToCharge: timeToCharge,
                batteryCycleCount: cycleCount,
                batteryHealth: getBatteryHealth(),
                batteryTemperature: batteryTemperature,
                chargerConnected: chargerConnected,
                optimizedBatteryChargingEngaged: optimizedBatteryCharging
            )
            return powerState
        }

        let client = PowerSourceClient(
            powerSourceChanges: {
                AsyncStream { continuation in
                    do {
                        let initialState = try getPowerSourceQueue.sync {
                            try getPowerSourceInfo()
                        }
                        continuation.yield(initialState)
                    } catch {
                        logger.error("Can't get the current power source info")
                    }
                    let id = UUID()
                    observer.addHandler(id) {
                        let powerState = try? getPowerSourceQueue.sync {
                            try getPowerSourceInfo()
                        }
                        if let powerState {
                            logger.notice("Power state did change: \(powerState, privacy: .public)")
                            continuation.yield(powerState)
                        } else {
                            logger.error("New power state, but there is an info missing")
                        }
                    }
                    continuation.onTermination = { _ in
                        observer.removeHandler(id)
                    }
                }
            },
            currentPowerSourceState: {

                let state = try getPowerSourceQueue.sync {
                    return try getPowerSourceInfo()
                }
                return state
            }
        )

        return client
    }()

    private class Observer {
        private let logger: Logger
        private var handlers = [UUID : () -> Void]()
        private let handlersQueue = DispatchQueue(label: "software.micropixels.BatFi.PowerSourceClient.Observer")

        init(logger: Logger) {
            self.logger = logger
            setUpObserving()
        }

        func setUpObserving() {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let loop: CFRunLoopSource = IOPSNotificationCreateRunLoopSource(
                {
                    context in
                    if let context {
                        let observer = Unmanaged<Observer>.fromOpaque(context).takeUnretainedValue()
                        observer.updateBatteryState()
                    }
                },
                context
            ).takeRetainedValue() as CFRunLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, CFRunLoopMode.commonModes)
        }

        func updateBatteryState() {
            logger.debug("New power state")
            handlersQueue.sync { [weak self] in
                self?.handlers.values.forEach { $0() }
            }
        }

        func removeHandler(_ id: UUID) {
            handlersQueue.sync { [weak self] in
                _ = self?.handlers.removeValue(forKey: id)
            }
        }

        func addHandler(_ id: UUID, _ handler: @escaping () -> Void) {
            handlersQueue.sync { [weak self] in
                self?.handlers[id] = handler
            }
        }
    }
}
