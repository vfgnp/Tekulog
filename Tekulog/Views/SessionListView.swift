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

    var body: some View {
        Group {
            if sessions.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                    .onDelete(perform: delete)
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

    private func delete(_ offsets: IndexSet) {
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
                    if session.activityKind == .walking {
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
