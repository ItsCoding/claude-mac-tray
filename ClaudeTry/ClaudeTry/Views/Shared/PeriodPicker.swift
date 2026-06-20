import SwiftUI

struct PeriodPicker: View {
    @Binding var selection: TimePeriod

    var body: some View {
        Picker("Period", selection: $selection) {
            ForEach(TimePeriod.allCases, id: \.self) { period in
                Text(period.rawValue).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
