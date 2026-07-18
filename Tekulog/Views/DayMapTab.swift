import SwiftUI

/// 地図タブ。日送り(前日/翌日・日付選択)付きで日別まとめを表示する。
struct DayMapTab: View {
    @State private var day = Calendar.current.startOfDay(for: Date())

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    /// DatePicker 用バインディング(選択値は常に startOfDay へ正規化)。
    private var dayBinding: Binding<Date> {
        Binding(
            get: { day },
            set: { day = Calendar.current.startOfDay(for: $0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    shift(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                DatePicker("表示する日", selection: dayBinding, in: ...today, displayedComponents: .date)
                    .labelsHidden()
                Spacer()
                Button {
                    shift(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(day >= today)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // DaySummaryView の FetchRequest は init 時に固定されるため、
            // 日が変わったら id でビューごと作り直す。
            DaySummaryView(day: day)
                .id(day)
        }
    }

    private func shift(by days: Int) {
        if let shifted = Calendar.current.date(byAdding: .day, value: days, to: day) {
            day = min(shifted, today)
        }
    }
}
