package base

// budget_applies is true where a test may judge a timing budget: only in an
// optimized build. A debug build's timing measures the compiler's debug code,
// not ours, so the unoptimized suite keeps its functional checks and leaves
// the clock to CI's "Optimized tests" step.
budget_applies :: proc() -> bool {
	return ODIN_OPTIMIZATION_MODE == .Speed || ODIN_OPTIMIZATION_MODE == .Aggressive
}
