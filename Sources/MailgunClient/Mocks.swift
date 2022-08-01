import ServerTestHelpers

#if DEBUG
  extension MailgunClient {
    public static let unimplemented = Self(
      sendEmail: { _ in
        .unimplemented("\(Self.self).sendEmail")
      }
    )
  }
#endif

extension MailgunClient {
  public static let noop = Self(
    sendEmail: { _ in
      .init(
        run: .init {
          .right(
            .init(
              id: "mailgun:id",
              message: "Success"
            )
          )
        }
      )
    }
  )
}
