import WimmDomain

// Forwarding shims: the free logging functions moved to WimmDomain.
// Internal so they are visible in this module without creating
// "ambiguous use" errors in files that also import WimmDomain.

internal func log(_ msg: String) { WimmDomain.log(msg) }
internal func logDebug(_ msg: String) { WimmDomain.logDebug(msg) }
internal func logAgent(_ msg: String) { WimmDomain.logAgent(msg) }
