import SwiftUI
import CoreData

/// カレンダー(Claude Design 画面4)。月グリッドで記録状況を一望し、
/// 表示月のセッションを「最近の記録」として並べる。日タップでその日の詳細へ。
struct CalendarView: View {
    @Environment(\.managedObjectContext) private var context
    @AppStorage(TekTheme.Keys.stepGoal) private var stepGoal = TekTheme.defaultStepGoal

    /// 表示中の月(1日固定)。
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DailyStat.day, ascending: true)],
        animation: .default
    )
    private var dailyStats: FetchedResults<DailyStat>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WalkSession.startedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil"),
        animation: .default
    )
    private var sessions: FetchedResults<WalkSession>

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }

    // List 内の NavigationLink は自動でディスクロージャ「>」を出してしまうため、
    // 遷移は Button + navigationDestination(item:) で明示的に駆動する。
    private struct NavDay: Identifiable, Hashable { let date: Date; var id: Date { date } }
    private struct NavSession: Identifiable, Hashable {
        let session: WalkSession
        var id: NSManagedObjectID { session.objectID }
    }
    @State private var navDay: NavDay?
    @State private var navSession: NavSession?

    var body: some View {
        List {
            Group {
                header
                monthCard
                legend
                SectionLabel("最近の記録")
                    .padding(.top, 4)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))

            ForEach(monthSessions) { session in
                sessionRow(session)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
            }
            .onDelete(perform: delete)

            if monthSessions.isEmpty {
                Text("この月の記録はまだありません")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TekTheme.sub)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TekTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $navDay) { DaySummaryView(day: $0.date) }
        .navigationDestination(item: $navSession) { SessionDetailView(session: $0.session) }
    }

    // MARK: - ヘッダー(タイトル+月送り)

    private var header: some View {
        HStack {
            Text("カレンダー")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(TekTheme.ink)
            Spacer()
            HStack(spacing: 14) {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                }
                Text(monthTitle)
                    .font(.system(size: 15, weight: .bold))
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                }
                .disabled(isCurrentMonth)
                .opacity(isCurrentMonth ? 0.3 : 1)
            }
            .foregroundStyle(TekTheme.ink)
        }
        .padding(.top, 14)
    }

    private var monthTitle: String {
        let comps = calendar.dateComponents([.year, .month], from: month)
        return "\(comps.year ?? 0)年\(comps.month ?? 0)月"
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private func shiftMonth(_ delta: Int) {
        if let shifted = calendar.date(byAdding: .month, value: delta, to: month),
           shifted <= Date() || calendar.isDate(shifted, equalTo: Date(), toGranularity: .month) {
            month = shifted
        }
    }

    // MARK: - 月グリッド

    /// その月のセル(先頭の空白+日)。
    private struct DayCell: Identifiable {
        let id: Int
        let day: Date?      // nil = 先頭の空白
        let number: Int
    }

    private var dayCells: [DayCell] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: month)  // 日曜=1
        var cells: [DayCell] = (0..<(firstWeekday - 1)).map { DayCell(id: -$0 - 1, day: nil, number: 0) }
        for dayNumber in range {
            let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: month)
            cells.append(DayCell(id: dayNumber, day: date, number: dayNumber))
        }
        return cells
    }

    /// 日別歩数の辞書(表示月ぶんだけあれば十分だが全件でも軽い)。
    private var stepsByDay: [Date: Int] {
        Dictionary(uniqueKeysWithValues: dailyStats.compactMap { stat in
            stat.day.map { ($0, Int(stat.steps)) }
        })
    }

    private var monthCard: some View {
        let weekdayLabels: [(String, Color)] = [
            ("日", TekTheme.coral), ("月", TekTheme.sub), ("火", TekTheme.sub),
            ("水", TekTheme.sub), ("木", TekTheme.sub), ("金", TekTheme.sub),
            ("土", TekTheme.primary)
        ]
        return TekCard(radius: 24, padding: 14) {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(weekdayLabels, id: \.0) { label, color in
                        Text(label)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(color)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                          spacing: 6) {
                    ForEach(dayCells) { cell in
                        if let day = cell.day {
                            dayCellView(day: day, number: cell.number)
                        } else {
                            Color.clear.frame(width: 34, height: 40)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCellView(day: Date, number: Int) -> some View {
        let steps = stepsByDay[day] ?? 0
        let isFuture = day > today
        let isToday = day == today
        let achieved = steps >= stepGoal && stepGoal > 0
        let recorded = steps > 0

        let outer: Color = achieved ? TekTheme.primary : (recorded ? TekTheme.paleGreen : TekTheme.background)
        let inner: Color = (achieved || recorded) ? .white : .clear
        let text: Color = (achieved || recorded) ? TekTheme.primaryDark
                        : (isFuture ? TekTheme.disabled : TekTheme.ink)

        Button {
            navDay = NavDay(date: day)
        } label: {
            ZStack {
                Circle().fill(outer).frame(width: 34, height: 34)
                Circle().fill(inner).frame(width: 26, height: 26)
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(text)
                if isToday {
                    Circle().stroke(TekTheme.coral, lineWidth: 2).frame(width: 34, height: 34)
                }
            }
            .frame(width: 34, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: TekTheme.primary, label: "目標達成")
            legendItem(color: TekTheme.paleGreen, label: "記録あり")
            HStack(spacing: 5) {
                Circle().stroke(TekTheme.coral, lineWidth: 2).frame(width: 11, height: 11)
                Text("今日").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(TekTheme.sub)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(TekTheme.sub)
    }

    // MARK: - 最近の記録(表示月のセッション)

    private var monthSessions: [WalkSession] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        return sessions.filter {
            guard let started = $0.startedAt else { return false }
            return interval.contains(started)
        }
    }

    private func kindColor(_ kind: ActivityKind) -> (icon: Color, background: Color) {
        switch kind {
        case .walking: return (TekTheme.primary, TekTheme.primaryPale)
        case .running: return (TekTheme.coral, TekTheme.coralPale)
        case .cycling: return (TekTheme.blue, TekTheme.bluePale)
        }
    }

    private func sessionRow(_ session: WalkSession) -> some View {
        let colors = kindColor(session.activityKind)
        return Button {
            navSession = NavSession(session: session)
        } label: {
            TekCard(radius: 18, padding: 12) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(colors.background)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: session.activityKind.symbolName)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(colors.icon)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.autoName)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(TekTheme.ink)
                        Text(rowSubtitle(session))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TekTheme.sub)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TekTheme.disabled)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func rowSubtitle(_ session: WalkSession) -> String {
        var parts = [Formatters.day(session.startedAt ?? Date()),
                     Formatters.distance(session.totalDistance)]
        if session.activityKind.countsSteps {
            parts.append(Formatters.steps(Int(session.totalSteps)))
        }
        return parts.joined(separator: "・")
    }

    private func delete(_ offsets: IndexSet) {
        let rows = monthSessions
        for index in offsets {
            context.delete(rows[index])
        }
        try? context.save()
    }
}
