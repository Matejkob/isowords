import ComposableArchitecture
import Styleguide
import SwiftUI

struct AccessibilitySettingsView: View {
  @State var store: StoreOf<Settings>

  var body: some View {
    SettingsForm {
      SettingsRow {
        VStack(alignment: .leading) {
          Toggle("Cube motion", isOn: self.$store.userSettings.enableGyroMotion)
            .adaptiveFont(.matterMedium, size: 16)

          Text("Use your device’s gyroscope to apply a small amount of motion to the cube.")
            .foregroundColor(.gray)
            .adaptiveFont(.matterMedium, size: 12)
            .transition(.opacity)
        }
      }
      SettingsRow {
        VStack(alignment: .leading) {
          Toggle("Haptics", isOn: self.$store.userSettings.enableHaptics)
            .adaptiveFont(.matterMedium, size: 16)
        }
      }
      SettingsRow {
        VStack(alignment: .leading) {
          Toggle(
            "Reduce animation",
            isOn: self.$store.userSettings.enableReducedAnimation
          )
          .adaptiveFont(.matterMedium, size: 16)
        }
      }
    }
    .navigationStyle(title: Text("Accessibility"))
  }
}

#if DEBUG
  import SwiftUIHelpers

  struct AccessibilitySettingsView_Previews: PreviewProvider {
    static var previews: some View {
      Preview {
        NavigationView {
          AccessibilitySettingsView(
            store: .init(initialState: Settings.State()) {
            }
          )
        }
      }
    }
  }
#endif
