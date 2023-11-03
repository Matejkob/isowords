import ComposableGameCenter

extension PastGame.State {
  init?(
    turnBasedMatch match: TurnBasedMatch,
    localPlayerId: Player.Id?
  ) {
    guard match.status == .ended
    else { return nil }

    guard let matchData = match.matchData?.turnBasedMatchData
    else { return nil }

    guard let endDate = matchData.moves.last?.playedAt
    else { return nil }

    guard
      match.participants.count == 2,
      let firstIndex = matchData.moves.first?.playerIndex?.rawValue,
      let challengerPlayer = match.participants[firstIndex].player,
      let challengeePlayer = match.participants[firstIndex == 0 ? 1 : 0].player
    else { return nil }

    guard
      let opponentIndex = match.participants
        .firstIndex(where: { $0.player?.gamePlayerId != localPlayerId })
    else { return nil }

    guard
      let opponentPlayer = match.participants[opponentIndex].player
    else { return nil }

    self.challengeeDisplayName = challengeePlayer.displayName
    self.challengeeScore = matchData.score(forPlayerIndex: 1)
    self.challengerDisplayName = challengerPlayer.displayName
    self.challengerScore = matchData.score(forPlayerIndex: 0)
    self.endDate = endDate
    self.matchId = match.matchId
    self.opponentDisplayName = opponentPlayer.displayName
  }
}

