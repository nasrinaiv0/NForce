/**
 * Explicit, exception-free result type for domain operations.
 *
 * Domain functions never throw for expected business failures (an invalid
 * transition, an insufficient balance, a forbidden action). They return a
 * `Result` so callers are forced by the type system to handle both paths.
 */
export type Ok<T> = { readonly ok: true; readonly value: T };
export type Err<E> = { readonly ok: false; readonly error: E };
export type Result<T, E> = Ok<T> | Err<E>;

export const ok = <T>(value: T): Ok<T> => ({ ok: true, value });
export const err = <E>(error: E): Err<E> => ({ ok: false, error });

/** A typed domain error with a stable machine-readable code. */
export interface DomainError<C extends string = string> {
  readonly code: C;
  readonly message: string;
}

export const domainError = <C extends string>(code: C, message: string): DomainError<C> => ({
  code,
  message,
});

/** Exhaustiveness guard for discriminated unions. */
export function assertNever(value: never, context = 'value'): never {
  throw new Error(`Unhandled ${context}: ${JSON.stringify(value)}`);
}
