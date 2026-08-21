# BotSpeaker engineering conventions

## Swift state observation

- Use the Observation framework's `@Observable` macro for reference-type UI state. Do not introduce new `ObservableObject` conformances or `@Published` properties.
- Pass an `@Observable` model to a SwiftUI view as a plain stored property when the view only reads it. Use `@Bindable` only when the view needs bindings to that model, and `@State` when the view owns the model's lifetime.
- Mark callbacks, framework objects, timers, caches, and other implementation-only storage with `@ObservationIgnored`.
- `@Observable` does not provide Combine `$property` publishers. Use explicit domain callbacks for one-off events or `withObservationTracking` when observation itself is required.
- Prefer migrating an existing `ObservableObject` when changing that type and the migration is contained. Avoid unrelated broad migrations in a feature change.
