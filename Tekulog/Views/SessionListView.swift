import SwiftUI
import CoreData

/// 記録一覧。終了済みセッションを新しい順に表示する。
struct SessionListView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WalkSession.startedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil"),
        animation: .default
    )
    private var sessions: FetchedResults<WalkSession>

    /// 日別(startOfDay)のセクション。新しい日が先頭。日内は fetch の降順のまま。
    private var dayGroups: [(day: Date, sessions: [WalkSession])] {
        Dictionary(grouping: sessions) { session in
            Calendar.current.startOfDay(for: session.startedAt ?? .distantPast)
        }
        .sorted { $0.key > $1.key }
        .map { (day: $0.key, sessions: $0.value) }
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(dayGroups, id: \.day) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    SessionDetailView(session: session)
                                } label: {
                                    SessionRow(session: session)
                                }
                            }
                            .onDelete { offsets in
                                delete(offsets, in: group.sessions)
                            }
                        } header: {
                            HStack {
                                Text(Formatters.day(group.day))
                                Spacer()
                                NavigationLink {
                                    DaySummaryView(day: group.day)
                                } label: {
                                    Label("地図", systemImage: "map")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("記録")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "まだ記録がありません",
            systemImage: "figure.walk.motion",
            description: Text("散歩や自転車を始めると自動で記録されます。")
        )
    }

    private func delete(_ offsets: IndexSet, in sessions: [WalkSession]) {
        for index in offsets {
            context.delete(sessions[index])
        }
        try? context.save()
    }
}

/// 一覧の1行。
struct SessionRow: View {
    @ObservedObject var session: WalkSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.activityKind.symbolName)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(Formatters.dateTime(session.startedAt ?? Date()))
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(Formatters.distance(session.totalDistance))
                    Text("・")
                    Text(Formatters.duration(session.duration))
                    if session.activityKind.countsSteps {
                        Text("・")
                        Text(Formatters.steps(Int(session.totalSteps)))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
