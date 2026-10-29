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
        HStack(spacing: 0) {
            Picker("Month", selection: $month) {
                Text("Month").tag(0)
                ForEach(1...12, id: \.self) { value in Text(String(value)).tag(value) }
            }
            .accessibilityIdentifier("birthdayMonth")
            Picker("Day", selection: $day) {
                Text("Day").tag(0)
                ForEach(1...31, id: \.self) { value in Text(String(value)).tag(value) }
            }
            .accessibilityIdentifier("birthdayDay")
            Picker("Year", selection: $year) {
                Text("Year").tag(0)
                ForEach(Array((currentYear - 120...currentYear).reversed()), id: \.self) { value in
                    Text(String(value)).tag(value)
                }
            }
            .accessibilityIdentifier("birthdayYear")
        }
        .pickerStyle(.wheel)
        .frame(height: 170)
        .onAppear {
            guard let birthday else { return }
            month = birthday.month
            day = birthday.day
            year = birthday.year
        }
        .onChange(of: month) { update() }
        .onChange(of: day) { update() }
        .onChange(of: year) { update() }
    }

    private func update() {
        let picked = Birthday(year: year, month: month, day: day)
        let calendar = Birthday.eligibilityCalendar
        birthday = picked.isValid && picked.date(in: calendar) <= calendar.startOfDay(for: .now) ? picked : nil
    }
}
