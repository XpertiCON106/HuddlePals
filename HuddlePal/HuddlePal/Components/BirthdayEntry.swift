import SwiftUI

/// All three values begin unselected. A birth date is never inferred from
/// an adult preset, and impossible dates cannot be submitted.
struct BirthdayEntry: View {
    @Binding var birthday: Birthday?
    @State private var month = 0
    @State private var day = 0
    @State private var year = 0

    private var currentYear: Int { Birthday.eligibilityCalendar.component(.year, from: .now) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Picker("Month", selection: monthSelection) {
                    Text("Month").tag(0)
                    ForEach(1...12, id: \.self) { value in Text(String(value)).tag(value) }
                }
                .accessibilityIdentifier("birthdayMonth")
                Picker("Day", selection: daySelection) {
                    Text("Day").tag(0)
                    ForEach(1...31, id: \.self) { value in Text(String(value)).tag(value) }
                }
                .accessibilityIdentifier("birthdayDay")
                Picker("Year", selection: yearSelection) {
                    Text("Year").tag(0)
                    ForEach(Array((currentYear - 120...currentYear).reversed()), id: \.self) { value in
                        Text(String(value)).tag(value)
                    }
                }
                .accessibilityIdentifier("birthdayYear")
            }
            .frame(height: 170)

            Text(birthday?.formatted() ?? "Select month, day, and year")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("selectedBirthday")
                .accessibilityValue(birthday?.isoDate ?? "Not selected")
        }
        .pickerStyle(.wheel)
        .onAppear {
            guard let birthday else { return }
            month = birthday.month
            day = birthday.day
            year = birthday.year
        }
    }

    private var monthSelection: Binding<Int> {
        Binding(get: { month }, set: { selected in
            month = selected
            update(month: selected, day: day, year: year)
        })
    }

    private var daySelection: Binding<Int> {
        Binding(get: { day }, set: { selected in
            day = selected
            update(month: month, day: selected, year: year)
        })
    }

    private var yearSelection: Binding<Int> {
        Binding(get: { year }, set: { selected in
            year = selected
            update(month: month, day: day, year: selected)
        })
    }

    private func update(month: Int, day: Int, year: Int) {
        let picked = Birthday(year: year, month: month, day: day)
        let calendar = Birthday.eligibilityCalendar
        birthday = picked.isValid && picked.date(in: calendar) <= calendar.startOfDay(for: .now) ? picked : nil
    }
}
