import SwiftUI

// Adapted from Blink (MIT, mo.software).
struct SimulatorRowView: View {
    @Environment(AppState.self) private var appState
    let simulator: Simulator

    @State private var isHovered = false

    private var state: AppState.ActionState? { appState.simulatorRestartStates[simulator.id] }
    private var isRestarting: Bool { state == .working }

    private var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let failureMessage {
                FailureBox(message: failureMessage)
                    .padding(.leading, HoverRowStyle.horizontalPadding + ColorBar.gutter)
                    .padding(.trailing, HoverRowStyle.horizontalPadding)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: failureMessage)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ColorBar(color: failureMessage == nil ? .xcode : Color.alert, isWorking: isRestarting)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: simulator.runningApp?.displayName ?? simulator.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                subtitle
            }

            Spacer(minLength: 8)

            if isHovered && !isRestarting {
                actions.transition(.opacity)
            }
        }
        .opacity(isRestarting ? 0.4 : 1)
        .allowsHitTesting(!isRestarting)
        .animation(.easeOut(duration: 0.2), value: isRestarting)
        .hoverRow { isHovered = $0 }
        .onTapGesture { appState.focusSimulator(simulator) }
    }

    @ViewBuilder
    private var subtitle: some View {
        Group {
            if isRestarting {
                Text("relaunching…").foregroundStyle(.secondary)
            } else if failureMessage != nil {
                Text("failed to relaunch").foregroundStyle(Color.alert)
            } else {
                Text(verbatim: "\(simulator.name) · \(simulator.runtime)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: RowAction.spacing) {
            if simulator.runningApp != nil {
                RowAction(symbol: "arrow.clockwise", help: "Relaunch app") {
                    appState.restartApp(in: simulator)
                }
            }

            if failureMessage == nil {
                RowAction(symbol: "xmark", help: "Shut down simulator", tint: .alert) {
                    appState.stopSimulator(simulator)
                }
            } else {
                RowAction(symbol: "xmark", help: "Dismiss", tint: .alert) {
                    appState.dismissSimulatorFailure(simulator)
                }
            }
        }
    }
}
