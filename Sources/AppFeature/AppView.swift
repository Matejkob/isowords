import ClientModels
import ComposableArchitecture
import ComposableGameCenter
import ComposableStoreKit
import ComposableUserNotifications
import CubeCore
import GameFeature
import HomeFeature
import NotificationHelpers
import OnboardingFeature
import ServerConfig
import ServerRouter
import SettingsFeature
import SharedModels
import Styleguide
import SwiftUI
import SwiftUIHelpers

public struct AppState: Equatable {
  public var game: GameState?
  public var onboarding: OnboardingState?
  public var home: Home.State

  public init(
    game: GameState? = nil,
    home: Home.State = .init(),
    onboarding: OnboardingState? = nil
  ) {
    self.game = game
    self.home = home
    self.onboarding = onboarding
  }

  public var currentGame: GameFeatureState {
    get {
      GameFeatureState(game: self.game, settings: self.home.settings)
    }
    set {
      let oldValue = self
      let isGameLoaded =
        newValue.game?.isGameLoaded == .some(true) || oldValue.game?.isGameLoaded == .some(true)
      let activeGames =
        newValue.game?.activeGames.isEmpty == .some(false)
        ? newValue.game?.activeGames
        : oldValue.game?.activeGames
      self.game = newValue.game
      self.game?.activeGames = activeGames ?? .init()
      self.game?.isGameLoaded = isGameLoaded
      self.home.settings = newValue.settings
    }
  }

  var isGameInActive: Bool {
    self.game == nil
  }

  var firstLaunchOnboarding: OnboardingState? {
    switch self.onboarding?.presentationStyle {
    case .some(.demo), .some(.help), .none:
      return nil

    case .some(.firstLaunch):
      return self.onboarding
    }
  }
}

public enum AppAction: Equatable {
  case appDelegate(AppDelegateReducer.Action)
  case currentGame(GameFeatureAction)
  case didChangeScenePhase(ScenePhase)
  case gameCenter(GameCenterAction)
  case home(Home.Action)
  case onboarding(OnboardingAction)
  case paymentTransaction(StoreKitClient.PaymentTransactionObserverEvent)
  case savedGamesLoaded(TaskResult<SavedGamesState>)
  case verifyReceiptResponse(TaskResult<ReceiptFinalizationEnvelope>)
}

extension AppEnvironment {
  var game: GameEnvironment {
    .init(
      apiClient: self.apiClient,
      applicationClient: self.applicationClient,
      audioPlayer: self.audioPlayer,
      backgroundQueue: self.backgroundQueue,
      build: self.build,
      database: self.database,
      dictionary: self.dictionary,
      feedbackGenerator: self.feedbackGenerator,
      fileClient: self.fileClient,
      gameCenter: self.gameCenter,
      lowPowerMode: self.lowPowerMode,
      mainQueue: self.mainQueue,
      mainRunLoop: self.mainRunLoop,
      remoteNotifications: self.remoteNotifications,
      serverConfig: self.serverConfig,
      storeKit: self.storeKit,
      userDefaults: self.userDefaults,
      userNotifications: self.userNotifications
    )
  }
}

public let appReducer = Reducer<AppState, AppAction, AppEnvironment>.combine(
  Reducer(
    Scope(state: \.home.settings.userSettings, action: /AppAction.appDelegate) {
      AppDelegateReducer()
    }
  ),

  gameFeatureReducer
    .pullback(
      state: \AppState.currentGame,
      action: /AppAction.currentGame,
      environment: \.game
    ),

  Reducer(
    Scope(state: \.home, action: /AppAction.home) {
      Home()
    }
  ),

  onboardingReducer
    .optional()
    .pullback(
      state: \.onboarding,
      action: /AppAction.onboarding,
      environment: {
        OnboardingEnvironment(
          audioPlayer: $0.audioPlayer,
          backgroundQueue: $0.backgroundQueue,
          dictionary: $0.dictionary,
          feedbackGenerator: $0.feedbackGenerator,
          lowPowerMode: $0.lowPowerMode,
          mainQueue: $0.mainQueue,
          mainRunLoop: $0.mainRunLoop,
          userDefaults: $0.userDefaults
        )
      }),

  appReducerCore
)
.gameCenter()
.storeKit()
.persistence()

extension Reducer where State == AppState, Action == AppAction, Environment == AppEnvironment {
  func persistence() -> Self {
    self
      .onChange(of: \.game?.moves) { moves, state, _, environment in
        guard let game = state.game, game.isSavable
        else { return .none }

        switch (game.gameContext, game.gameMode) {
        case (.dailyChallenge, .unlimited):
          state.home.savedGames.dailyChallengeUnlimited = InProgressGame(gameState: game)
        case (.shared, .unlimited), (.solo, .unlimited):
          state.home.savedGames.unlimited = InProgressGame(gameState: game)
        case (.turnBased, _), (_, .timed):
          return .none
        }
        return .none
      }
      .onChange(of: \.home.savedGames) { savedGames, _, action, environment in
        if case .savedGamesLoaded(.success) = action { return .none }
        return .fireAndForget {
          try await environment.fileClient.save(games: savedGames)
        }
      }
  }
}

let appReducerCore = Reducer<AppState, AppAction, AppEnvironment> { state, action, environment in
  switch action {
  case .appDelegate(.didFinishLaunching):
    if !environment.userDefaults.hasShownFirstLaunchOnboarding {
      state.onboarding = .init(presentationStyle: .firstLaunch)
    }

    return .run { send in
      async let migrate: Void = environment.database.migrate()
      if environment.userDefaults.installationTime <= 0 {
        async let setInstallationTime: Void = environment.userDefaults.setInstallationTime(
          environment.mainRunLoop.now.date.timeIntervalSinceReferenceDate
        )
      }
      await send(
        .savedGamesLoaded(
          TaskResult { try await environment.fileClient.loadSavedGames() }
        )
      )
    }

  case let .appDelegate(.userNotifications(.didReceiveResponse(response, completionHandler))):
    if
      let data =
        try? JSONSerialization
        .data(withJSONObject: response.notification.request.content.userInfo),
      let pushNotificationContent = try? JSONDecoder()
        .decode(PushNotificationContent.self, from: data)
    {
      switch pushNotificationContent {
      case .dailyChallengeEndsSoon:
        if let inProgressGame = state.home.savedGames.dailyChallengeUnlimited {
          state.currentGame = GameFeatureState(
            game: GameState(inProgressGame: inProgressGame),
            settings: state.home.settings
          )
        } else {
          // TODO: load/retry
        }

      case .dailyChallengeReport:
        state.game = nil
        state.home.route = .dailyChallenge(.init())
      }
    }

    return .fireAndForget { completionHandler() }

  case .appDelegate:
    return .none

  case .currentGame(.game(.endGameButtonTapped)),
    .currentGame(.game(.gameOver(.task))):

    switch (state.game?.gameContext, state.game?.gameMode) {
    case (.dailyChallenge, .unlimited):
      state.home.savedGames.dailyChallengeUnlimited = nil
    case (.solo, .unlimited):
      state.home.savedGames.unlimited = nil
    default:
      break
    }
    return .none

  case .currentGame(.game(.activeGames(.dailyChallengeTapped))),
    .home(.activeGames(.dailyChallengeTapped)):
    guard let inProgressGame = state.home.savedGames.dailyChallengeUnlimited
    else { return .none }

    state.currentGame = .init(
      game: GameState(inProgressGame: inProgressGame),
      settings: state.home.settings
    )
    return .none

  case .currentGame(.game(.activeGames(.soloTapped))),
    .home(.activeGames(.soloTapped)):
    guard let inProgressGame = state.home.savedGames.unlimited
    else { return .none }

    state.currentGame = .init(
      game: GameState(inProgressGame: inProgressGame),
      settings: state.home.settings
    )
    return .none

  case let .currentGame(.game(.activeGames(.turnBasedGameTapped(matchId)))),
    let .home(.activeGames(.turnBasedGameTapped(matchId))):
    return .run { send in
      do {
        let match = try await environment.gameCenter.turnBasedMatch.load(matchId)
        await send(
          .gameCenter(
            .listener(.turnBased(.receivedTurnEventForMatch(match, didBecomeActive: true)))
          ),
          animation: .default
        )
      } catch {}
    }

  case .currentGame(.game(.exitButtonTapped)),
    .currentGame(.game(.gameOver(.delegate(.close)))):
    state.game = nil
    return .none

  case .currentGame(.game(.gameOver(.delegate(.startSoloGame(.timed))))),
    .home(.solo(.gameButtonTapped(.timed))):
    state.game = .init(
      cubes: environment.dictionary.randomCubes(.en),
      gameContext: .solo,
      gameCurrentTime: environment.mainRunLoop.now.date,
      gameMode: .timed,
      gameStartTime: environment.mainRunLoop.now.date,
      isGameLoaded: state.currentGame.game?.isGameLoaded == .some(true)
    )
    return .none

  case .currentGame(.game(.gameOver(.delegate(.startSoloGame(.unlimited))))),
    .home(.solo(.gameButtonTapped(.unlimited))):
    state.game =
      state.home.savedGames.unlimited
      .map { GameState(inProgressGame: $0) }
      ?? GameState(
        cubes: environment.dictionary.randomCubes(.en),
        gameContext: .solo,
        gameCurrentTime: environment.mainRunLoop.now.date,
        gameMode: .unlimited,
        gameStartTime: environment.mainRunLoop.now.date,
        isGameLoaded: state.currentGame.game?.isGameLoaded == .some(true)
      )
    return .none

  case .currentGame:
    return .none

  case let .home(.dailyChallenge(.delegate(.startGame(inProgressGame)))):
    state.game = .init(inProgressGame: inProgressGame)
    return .none

  case let .home(.dailyChallengeResponse(.success(dailyChallenges))):
    if dailyChallenges.unlimited?.dailyChallenge.id
      != state.home.savedGames.dailyChallengeUnlimited?.dailyChallengeId
    {
      state.home.savedGames.dailyChallengeUnlimited = nil
      return .fireAndForget { [savedGames = state.home.savedGames] in
        try await environment.fileClient.save(games: savedGames)
      }
    }
    return .none

  case .home(.howToPlayButtonTapped):
    state.onboarding = .init(presentationStyle: .help)
    return .none

  case .didChangeScenePhase(.active):
    return .fireAndForget {
      async let register: Void = registerForRemoteNotificationsAsync(
        remoteNotifications: environment.remoteNotifications,
        userNotifications: environment.userNotifications
      )
      async let refresh = environment.serverConfig.refresh()
    }

  case .didChangeScenePhase:
    return .none

  case .gameCenter:
    return .none

  case .home:
    return .none

  case let .onboarding(.delegate(action)):
    switch action {
    case .getStarted:
      state.onboarding = nil
      return .none
    }

  case .onboarding:
    return .none

  case .paymentTransaction:
    return .none

  case .savedGamesLoaded(.failure):
    return .none

  case let .savedGamesLoaded(.success(savedGames)):
    state.home.savedGames = savedGames
    return .none

  case .verifyReceiptResponse:
    return .none
  }
}

public struct AppView: View {
  let store: Store<AppState, AppAction>
  @ObservedObject var viewStore: ViewStore<ViewState, AppAction>
  @Environment(\.deviceState) var deviceState

  struct ViewState: Equatable {
    let isGameActive: Bool
    let isOnboardingPresented: Bool

    init(state: AppState) {
      self.isGameActive = state.game != nil
      self.isOnboardingPresented = state.onboarding != nil
    }
  }

  public init(store: Store<AppState, AppAction>) {
    self.store = store
    self.viewStore = ViewStore(self.store.scope(state: ViewState.init))
  }

  public var body: some View {
    Group {
      if !self.viewStore.isOnboardingPresented && !self.viewStore.isGameActive {
        NavigationView {
          HomeView(store: self.store.scope(state: \.home, action: AppAction.home))
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .zIndex(0)
      } else {
        IfLetStore(
          self.store.scope(
            state: { appState in
              appState.game.map {
                (
                  game: $0,
                  nub: CubeSceneView.ViewState.NubState?.none,
                  settings: CubeSceneView.ViewState.Settings(
                    enableCubeShadow: appState.home.settings.enableCubeShadow,
                    enableGyroMotion: appState.home.settings.userSettings.enableGyroMotion,
                    showSceneStatistics: appState.home.settings.showSceneStatistics
                  )
                )
              }
            }
          ),
          then: { gameAndSettingsStore in
            GameFeatureView(
              content: CubeView(
                store: gameAndSettingsStore.scope(
                  state: CubeSceneView.ViewState.init(game:nub:settings:),
                  action: { .currentGame(.game(CubeSceneView.ViewAction.to(gameAction: $0))) }
                )
              ),
              store: self.store.scope(state: \.currentGame, action: AppAction.currentGame)
            )
          }
        )
        .transition(.game)
        .zIndex(1)

        IfLetStore(
          self.store.scope(state: \.onboarding, action: AppAction.onboarding),
          then: OnboardingView.init(store:)
        )
        .zIndex(2)
      }
    }
    .modifier(DeviceStateModifier())
  }
}

#if DEBUG
  struct AppView_Previews: PreviewProvider {
    static var previews: some View {
      AppView(
        store: .init(
          initialState: .init(),
          reducer: appReducer,
          environment: .noop
        )
      )
    }
  }
#endif
