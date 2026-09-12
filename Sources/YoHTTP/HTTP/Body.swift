import NIOCore
import Synchronization

/// A single-subscriber, event-driven request body.
public struct Body: Sendable {
	private let streamStorage: BodyStream

	public static var empty: Body {
		let stream = BodyStream()
		stream.finish()
		return Body(stream: stream)
	}

	init(stream: BodyStream) { streamStorage = stream }

	public func stream() -> BodyStream { streamStorage }
}

public final class BodyStream: Sendable {
	public enum Error: Swift.Error, Sendable, Equatable {
		case alreadySubscribed
		case cancelled
		case tooLarge(limit: Int)
		case timedOut
	}

	private struct State: Sendable {
		var onChunk: (@Sendable (ByteBuffer) -> Void)?
		var onEnd: (@Sendable () -> Void)?
		var onError: (@Sendable (Error) -> Void)?
		var subscribed = false
		var terminal: Error??
		var paused = false
		var control: (@Sendable (Bool) -> Void)?
	}

	private let state = Mutex(State())

	init(control: (@Sendable (Bool) -> Void)? = nil) {
		state.withLock { $0.control = control }
	}

	@discardableResult
	public func onChunk(_ callback: @escaping @Sendable (ByteBuffer) -> Void) -> Self {
		let result = state.withLock { value -> (Error?, (@Sendable (Error) -> Void)?) in
			guard !value.subscribed else { return (.alreadySubscribed, value.onError) }
			value.subscribed = true
			value.onChunk = callback
			if let terminal = value.terminal, let error = terminal {
				return (error, value.onError)
			}
			return (nil, nil)
		}
		if let error = result.0 { result.1?(error) }
		return self
	}

	@discardableResult
	public func onEnd(_ callback: @escaping @Sendable () -> Void) -> Self {
		let completed = state.withLock { value -> Bool in
			value.onEnd = callback
			guard let terminal = value.terminal else { return false }
			return terminal == nil
		}
		if completed { callback() }
		return self
	}

	@discardableResult
	public func onError(_ callback: @escaping @Sendable (Error) -> Void) -> Self {
		let error = state.withLock { value -> Error? in
			value.onError = callback
			guard let terminal = value.terminal else { return nil }
			return terminal
		}
		if let error { callback(error) }
		return self
	}

	public func pause() {
		let control = state.withLock { value -> (@Sendable (Bool) -> Void)? in
			guard !value.paused, value.terminal == nil else { return nil }
			value.paused = true
			return value.control
		}
		control?(true)
	}

	public func resume() {
		let control = state.withLock { value -> (@Sendable (Bool) -> Void)? in
			guard value.paused, value.terminal == nil else { return nil }
			value.paused = false
			return value.control
		}
		control?(false)
	}

	func receive(_ buffer: ByteBuffer) { state.withLock { $0.onChunk }?(buffer) }

	func finish() {
		let callback = state.withLock { value -> (@Sendable () -> Void)? in
			guard value.terminal == nil else { return nil }
			value.terminal = .some(nil)
			return value.onEnd
		}
		callback?()
	}

	func fail(_ error: Error) {
		let callback = state.withLock { value -> (@Sendable (Error) -> Void)? in
			guard value.terminal == nil else { return nil }
			value.terminal = .some(error)
			return value.onError
		}
		callback?(error)
	}
}
