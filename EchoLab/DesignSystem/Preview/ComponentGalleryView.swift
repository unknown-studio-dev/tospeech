import SwiftUI

enum ComponentGallerySection: String, CaseIterable, Identifiable {
  case d00 = "D00 · Đối chiếu"
  case foundations = "Nền tảng"
  case controls = "Controls"
  case practice = "Luyện tập"
  case feedback = "Phản hồi"
  case sheets = "Sheet & popover"
  var id: String { rawValue }
}

struct ComponentGalleryView: View {
  @State var section: ComponentGallerySection = .d00
  @State private var reduceMotion = false
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 20) {
        EchoBrandLabel(size: 32).padding(.bottom, 8)
        ForEach(ComponentGallerySection.allCases) { item in
          Button {
            section = item
          } label: {
            EchoLocalizedText(item.rawValue).frame(maxWidth: .infinity, alignment: .leading)
              .padding(10).foregroundStyle(
                section == item ? EchoTheme.accent : EchoTheme.secondaryText
              )
              .background(
                section == item ? EchoTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: EchoMetrics.controlRadius))
          }.buttonStyle(.plain).accessibilityAddTraits(section == item ? .isSelected : [])
        }
        Spacer()
        Text("Pencil D00 → SwiftUI\nDữ liệu ví dụ để kiểm tra UI.")
          .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
      }.padding(20).frame(width: 210).background(EchoTheme.surface)
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack {
            VStack(alignment: .leading, spacing: 6) {
              EchoLocalizedText(section.rawValue).font(EchoFont.heading(size: 28, weight: .semibold))
              Text("Thử hover, Tab, Space, phím mũi tên và Escape.")
                .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
            }
            Spacer()
            Toggle("Giảm chuyển động", isOn: $reduceMotion).toggleStyle(EchoToggleStyle())
              .font(EchoFont.metadata).fixedSize()
          }
          switch section {
          case .d00: D00CatalogView()
          case .foundations: FoundationSpecimens()
          case .controls: ControlSpecimens()
          case .practice: PracticeSpecimens()
          case .feedback: FeedbackSpecimens()
          case .sheets: PresentationSpecimens()
          }
        }.padding(32).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)
      }.background(EchoTheme.canvas)
    }.font(EchoFont.body(size: 14)).foregroundStyle(EchoTheme.text)
      .tint(EchoTheme.accent).preferredColorScheme(.dark)
      .environment(\.echoReduceMotion, systemReduceMotion || reduceMotion)
      .frame(minWidth: 1000, minHeight: 720)
  }
}

struct SpecimenSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content
  var body: some View {
    EchoPanel {
      VStack(alignment: .leading, spacing: 20) {
        EchoLocalizedText(title).font(EchoFont.heading(size: 18, weight: .semibold))
        content
      }
    }
  }
}

private struct FoundationSpecimens: View {
  var body: some View {
    SpecimenSection(title: "Logo & màu sắc") {
      HStack(spacing: 24) {
        EchoBrandMark(size: 96)
        EchoBrandLabel(title: "Cách bạn học", size: 44)
        Spacer()
        EchoBrandMark(size: 24)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 116))], spacing: 16) {
        ForEach(DesignSystemFixtures.palette, id: \.0) { name, color, hex in
          VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8).fill(color).frame(height: 42)
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(EchoTheme.border))
            EchoLocalizedText(name).font(EchoFont.body(size: 13, weight: .medium))
            Text(hex).font(EchoFont.mono(size: 11)).foregroundStyle(EchoTheme.secondaryText)
          }
        }
      }
    }
    SpecimenSection(title: "SF Pro · SF Mono · IPA") {
      Text("Listen. Notice. Try again.").font(EchoFont.sentence)
      Text(DesignSystemFixtures.ipaGlyphs).font(EchoFont.ipa).foregroundStyle(
        EchoTheme.secondaryText)
      Text(DesignSystemFixtures.translation).font(EchoFont.translation)
      Text("00:18.250 → 00:21.750").font(EchoFont.mono(size: 14))
      Text("EN 30 · IPA 16 · VI 17 · Control 14 · Metadata 12")
        .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText)
    }
    SpecimenSection(title: "Khoảng cách & chuyển động") {
      HStack(alignment: .bottom, spacing: 24) {
        ForEach(EchoMetrics.spacing, id: \.self) { value in
          VStack(spacing: 8) {
            Rectangle().fill(EchoTheme.accent).frame(width: value, height: 32)
            Text("\(Int(value)) pt").font(EchoFont.metadata)
          }
        }
      }
      Text(
        "Hover 120 ms · Nội dung 160 ms · Panel 200 ms\nFocus và trạng thái audio cập nhật ngay. Reduce Motion tắt hiệu ứng custom."
      )
      .font(EchoFont.body(size: 13)).foregroundStyle(EchoTheme.secondaryText)
    }
  }
}
