#+build !windows
package platform_common

import "common:base"

// stack_service: nothing off Windows (POSIX threads answer the crash signal themselves).
@(private)
stack_service :: proc() -> base.Stack_Service {
	return {}
}
