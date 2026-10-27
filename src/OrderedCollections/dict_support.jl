# support functions

# _tablesz and hashindex are defined in Base, but are not exported,
# so they are redefined here.
_tablesz(x::Integer) = x < 16 ? 16 : one(x)<<((sizeof(x)<<3)-leading_zeros(x-1))
hashindex(key, sz) = (reinterpret(Int,(hash(key))) & (sz-1)) + 1

const orderedset_seed = UInt === UInt64 ? 0x2114638a942a91a5 : 0xd86bdbf1

struct NotFoundSentinel end  # Struct to mark not not found
