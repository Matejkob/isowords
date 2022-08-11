import Combine
import CombineHelpers
import ComposableArchitecture
import ComposableUserNotifications
import NotificationHelpers
import RemoteNotificationsClient
import Styleguide
import SwiftUI

public struct NotificationsAuthAlertDelegate {
  public var didChooseNotificationSettings:
    @Sendable (UserNotificationClient.Notification.Settings) async -> Void = { _ in }
}

extension DependencyValues {
  public var notificationsAuthAlertDelegate: NotificationsAuthAlertDelegate {
    get { self[NotificationsAuthAlertDelegateKey.self] }
    set { self[NotificationsAuthAlertDelegateKey.self] = newValue }
  }

  private enum NotificationsAuthAlertDelegateKey: LiveDependencyKey {
    static let liveValue = NotificationsAuthAlertDelegate()
    static let testValue = NotificationsAuthAlertDelegate()
  }
}

public struct NotificationsAuthAlert: ReducerProtocol {
  public struct State: Equatable {
    public init() {}
  }

  public enum Action: Equatable {
    case turnOnNotificationsButtonTapped
  }

  @Dependency(\.dismiss) var dismiss
  @Dependency(\.mainRunLoop) var mainRunLoop
  @Dependency(\.notificationsAuthAlertDelegate) var delegate
  @Dependency(\.remoteNotifications) var remoteNotifications
  @Dependency(\.userNotifications) var userNotifications

  public init() {}

  public func reduce(into state: inout State, action: Action) -> Effect<Action, Never> {
    switch action {
    case .turnOnNotificationsButtonTapped:
      return .run { send in
        if try await self.userNotifications.requestAuthorization([.alert, .sound]) {
          await registerForRemoteNotificationsAsync(
            remoteNotifications: self.remoteNotifications,
            userNotifications: self.userNotifications
          )
        }
        await self.delegate.didChooseNotificationSettings(
          self.userNotifications.getNotificationSettings()
        )
        await self.dismiss()
      }
    }
  }
}

extension View {
  public func notificationsAlert<State, Action>(
    store: Store<PresentationState<State>, PresentationAction<State, Action>>,
    state toAlertState: @escaping (State) -> NotificationsAuthAlert.State?,
    action fromAlertAction: @escaping (NotificationsAuthAlert.Action) -> Action
  ) -> some View {
    ZStack {
      self

      WithViewStore(store.stateless) { viewStore in
        IfLetStore(
          store.scope(
            state: { $0.wrappedValue.flatMap(toAlertState) },
            action: { .presented(fromAlertAction($0)) }
          )
        ) {
          NotificationsAuthAlertView(
            store: $0,
            dismiss: { viewStore.send(.dismiss, animation: .default) }
          )
        }
      }
      // NB: This is necessary so that when the alert is animated away it stays above `self`.
      .zIndex(1)
    }
  }
}

struct NotificationsAuthAlertView: View {
  let store: StoreOf<NotificationsAuthAlert>
  let dismiss: () -> Void

  var body: some View {
    WithViewStore(self.store) { viewStore in
      Rectangle()
        .fill(Color.dailyChallenge.opacity(0.8))
        .ignoresSafeArea()

      ZStack(alignment: .topTrailing) {
        VStack(spacing: .grid(8)) {
          (Text("Want to get notified about ")
            + Text("your ranks?").fontWeight(.medium))
            .adaptiveFont(.matter, size: 28)
            .foregroundColor(.dailyChallenge)
            .lineLimit(.max)
            .minimumScaleFactor(0.2)
            .multilineTextAlignment(.center)

          Button("Turn on notifications") {
            viewStore.send(.turnOnNotificationsButtonTapped, animation: .default)
          }
          .buttonStyle(ActionButtonStyle(backgroundColor: .dailyChallenge, foregroundColor: .black))
        }
        .padding(.top, .grid(4))
        .padding(.grid(8))
        .background(Color.black)

        Button(action: self.dismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 20))
            .foregroundColor(.dailyChallenge)
            .padding(.grid(5))
        }
      }
      .transition(
        AnyTransition.scale(scale: 0.8, anchor: .center)
          .animation(.spring())
          .combined(with: .opacity)
      )
    }
  }
}

struct NotificationMenu_Previews: PreviewProvider {
  static var previews: some View {
    NotificationsAuthAlertView(
      store: Store(
        initialState: NotificationsAuthAlert.State(),
        reducer: NotificationsAuthAlert()
      ),
      dismiss: {}
    )
  }
}
