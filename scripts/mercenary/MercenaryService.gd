class_name MercenaryService
extends RefCounted

static func sell_refund(cost: int) -> int:
	return maxi(0, cost)
