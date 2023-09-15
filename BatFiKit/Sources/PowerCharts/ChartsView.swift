//
//  ChartsView.swift
//
//
//  Created by Adam on 19/08/2023.
//

import AppShared
import Clients
import Dependencies
import L10n
import Persistence
import SwiftUI
import Charts

public struct ChartsView: View {
    @StateObject private var model = Model()
    @Dependency(\.calendar) private var calendar

    public init() { }

    public var body: some View {
        VStack(alignment: .leading) {
            Text(L10n.Menu.Charts.chartsHeader)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.bottom, 6)
            if !model.powerStatePoints.isEmpty {
                Chart {
                    RectangleMark(
                        xStart: .value("From date", model.fromDate),
                        xEnd: .value("To date", model.toDate)
                    )
                    .foregroundStyle(Color.clear)
                    
                    ForEach(model.powerStatePoints) {
                        let offsetDate = model.offsetDateFor($0)
                        RectangleMark(
                            xStart: .value("Time", $0.timestamp),
                            xEnd: .value("Time", offsetDate),
                            yStart: .value("zero", 0),
                            yEnd: .value("level", $0.batteryLevel)
                        )
                        .foregroundStyle(barForegroundColorFor($0))

                        RectangleMark(
                            xStart: .value("Time", $0.timestamp),
                            xEnd: .value("Time", offsetDate),
                            yStart: .value("zero", $0.chargerConnected ? $0.batteryLevel : 100),
                            yEnd: .value("level", 100)
                        )
                        .foregroundStyle(chargerConnectedForegrondColorFor($0))

                        LineMark(
                            x: .value("Time", $0.timestamp ..< offsetDate),
                            y: .value("Battery Level", $0.batteryLevel)
                        )
                        .foregroundStyle(by: .value("visual battery", $0.visualBatteryState))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartForegroundStyleScale(domain: VisualBatteryState.allCases, mapping: {
                    switch $0 {
                    case .normal:
                        Color(.chartBlue)
                    case .low:
                        Color(.chartRed)
                    }
                })
                .chartYAxis {
                    AxisMarks(
                        values: [0, 50, 100]
                    ) {
                        AxisValueLabel(format: Decimal.FormatStyle.Percent.percent.scale(1))
                    }

                    AxisMarks(
                        values: [0, 25, 50, 75, 100]
                    ) {
                        AxisGridLine()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 3, roundLowerBound: true)) { value in
                        if let date = value.as(Date.self) {
                            let hour = calendar.component(.hour, from: date)
                            AxisValueLabel {
                                Text(date, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
                            }
                            if hour == 0 {
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            } else {
                                AxisGridLine()
                                AxisTick()
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 3) {
                    LegendView(label: Representation.charging.description, color: Color(.chartLightGreen))
                    LegendView(label: Representation.inhibiting.description, color: Color(.chartLightOrange))
                }
            } else {
                Text(L10n.Menu.Charts.waitingForData)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chargerConnectedForegrondColorFor(_ powerStatePoint: PowerStatePoint) -> Color {
        if powerStatePoint.chargerConnected && powerStatePoint.appMode.representation == .charging {
            return Color(.chartLightGreen)
        } else {
            return Color(.chartLightOrange)
        }
    }

    private func barForegroundColorFor(_ powerStatePoint: PowerStatePoint) -> Color {
        switch powerStatePoint.appMode.representation {
        case .charging:
            return Color(.chartGreen)
        case .inhibiting:
            return Color(.chartLightGreen)
        case .discharging:
            return .clear
        }
    }
}

extension AppChargingMode {
    fileprivate var representation: Representation {
        switch self {
        case .initial, .inhibit:
            return .inhibiting
        case .charging, .forceCharge:
            return .charging
        case .forceDischarge, .chargerNotConnected:
            return .discharging
        }
    }
}

private enum Representation: String, Plottable, CaseIterable {
    case charging
    case inhibiting
    case discharging

    var description: String {
        switch self {
        case .charging:
            return L10n.AppChargingMode.State.Title.charging
        case .inhibiting:
            return L10n.AppChargingMode.State.Title.inhibit
        case .discharging:
            return L10n.AppChargingMode.State.Title.forceDischarge
        }
    }
}

enum VisualBatteryState: String, Plottable, CaseIterable {
    case low
    case normal
}

extension PowerStatePoint {
    fileprivate var visualBatteryState: VisualBatteryState {
        if self.batteryLevel <= 20 {
            return .low
        } else {
            return .normal
        }
    }
}