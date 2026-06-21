import SwiftUI

/// Segmented preset picker with an inline custom date range. Selecting "Custom"
/// reveals two date pickers; everything else resolves through `RangeState`.
struct RangePicker: View {
    @Binding var range: RangeState

    var body: some View {
        VStack(spacing: 8) {
            Picker("Range", selection: $range.mode) {
                ForEach(RangeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if range.mode == .custom {
                HStack(spacing: 6) {
                    DatePicker("", selection: $range.customStart, in: ...range.customEnd,
                               displayedComponents: .date)
                        .labelsHidden()
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    DatePicker("", selection: $range.customEnd, in: range.customStart...,
                               displayedComponents: .date)
                        .labelsHidden()
                    Spacer()
                }
                .datePickerStyle(.compact)
            }
        }
    }
}
