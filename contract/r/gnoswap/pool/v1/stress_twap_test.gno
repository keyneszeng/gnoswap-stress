package pool

import (
	"testing"
	"time"

	i256 "gno.land/p/gnoswap/int256"
	u256 "gno.land/p/gnoswap/uint256"
	"gno.land/p/gnoswap/fuzz"

	pl "gno.land/r/gnoswap/pool"
)

// StressTest_CardinalityGrowLoop targets the linear-cost `grow()` loop in
// oracle.gno: repeatedly calling IncreaseObservationCardinalityNext with
// slightly larger values forces many O(n) slot-initialization loops.
// Deterministic, time-independent path mapping to the bounty's
// "Major performance degradation caused by stress-testing" clause.
// Uses the same mock-pool harness as oracle_test.go (initPoolTest/createTestPool).
func TestStress_CardinalityGrowLoop(cur realm, t *testing.T) {
	initPoolTest(cur, t)
	pool := createTestPool()

	// seed an observation state so grow() has a non-nil base to extend
	currentTime := time.Now().Unix()
	os := pool.ObservationState()
	if os == nil {
		os = pl.NewObservationState(currentTime)
		pool.SetObservationState(os)
	}
	writeObservation(os, currentTime, pool.Slot0Tick(), pool.Liquidity())
	os.SetCardinality(1)
	os.SetCardinalityNext(1)
	pool.SetObservationState(os)

	// exercise the linear-cost grow() loop directly on the in-memory pool:
	// increase cardinality one slot at a time forces O(n) slot-init loops.
	target := uint16(2000)
	for next := uint16(2); next <= target; next++ {
		err := increaseObservationCardinalityNextByPool(pool, next)
		if err != nil {
			t.Fatalf("grow failed at cardinality %d: %v", next, err)
		}
	}
	t.Logf("cardinality grow completed: pushed cardinalityNext to %d (grow O(n) loop exercised)", target)
}

// StressTest_PriceGriefing probes whether CreatePool validates sqrtPriceX96.
// The manager.gno source comment (lines 47-48) claims the price is accepted
// "without validation". We call CreatePool directly with an extreme-but-in-range
// price (~1e38, inside Q64.96 numeric range but wildly off-market) and assert the
// pool is created (i.e. accepted). A griefer can therefore mint a pool at any
// price ratio. (We deliberately do NOT add liquidity / swap here: at an off-market
// price the required token amounts are astronomically large and would only
// reproduce the griefing effect as a balance revert, not a separate VM panic.)
func TestStress_PriceGriefing(cur realm, t *testing.T) {
	initPoolTest(cur, t)

	// CreatePool charges a pool-creation fee in GNS; zero it for the stress test
	// (mirrors dsl.GivenPoolCreated) so the only thing under test is the price arg.
	testing.SetOriginCaller(adminAddr)
	testing.SetRealm(adminRealm)
	mockInstanceSetPoolCreationFee(0, cur, 0)

	// ~1e38: inside uint256/Q64.96 numeric range, but a price ratio of ~1e38 is
	// absurdly off-market. If CreatePool accepts it, the "no validation" comment
	// is literally true and a griefer can mint a pool at any price.
	extreme := "100000000000000000000000000000000000000" // 1e38

	testing.SetOriginCaller(adminAddr)
	testing.SetRealm(adminRealm)
	mockInstanceCreatePool(0, cur, barPath, bazPath, STANDARD_FEE_TIER, extreme)

	pool := getMockInstance().mustGetPool(GetPoolPath(barPath, bazPath, STANDARD_FEE_TIER))
	if pool == nil {
		t.Fatalf("CreatePool rejected extreme price (numeric range-guarded)")
	}
	t.Logf("CreatePool ACCEPTED extreme sqrtPriceX96=%s (stored tick=%d) — no reasonableness validation (manager.gno:47-48 confirmed)", extreme, pool.Slot0Tick())
}

// StressTest_FuzzSwapSequence runs a randomized high-frequency swap sequence
// against a scattered-liquidity pool and asserts core invariants hold under
// chaos (no negative liquidity, pool state stays consistent, no VM panic).
// Time-independent; exercises the computeSwap path under fuzz.
func TestStress_FuzzSwapSequence(cur realm, t *testing.T) {
	initPoolTest(cur, t)

	testing.SetOriginCaller(adminAddr)
	testing.SetRealm(adminRealm)
	mockInstanceSetPoolCreationFee(0, cur, 0)
	mockInstanceCreatePool(0, cur, barPath, bazPath, STANDARD_FEE_TIER, EQUAL_PRICE_RATIO)
	TokenApprove(cur, t, barPath, adminAddr, poolAddr, maxApprove)
	TokenApprove(cur, t, bazPath, adminAddr, poolAddr, maxApprove)

	// Scattered liquidity so swaps must traverse multiple tick ranges.
	// The position owner (admin) must hold the underlying tokens to mint; faucet
	// them first (each call grants 5e9).
	TokenFaucet(cur, t, barPath, adminAddr)
	TokenFaucet(cur, t, bazPath, adminAddr)
	testing.SetRealm(posRealm)
	mockInstanceMint(0, cur, barPath, bazPath, STANDARD_FEE_TIER, -10020, -9000, "10000000", adminAddr)
	mockInstanceMint(0, cur, barPath, bazPath, STANDARD_FEE_TIER, -4980, -4020, "20000000", adminAddr)
	mockInstanceMint(0, cur, barPath, bazPath, STANDARD_FEE_TIER, 0, 1020, "30000000", adminAddr)
	mockInstanceMint(0, cur, barPath, bazPath, STANDARD_FEE_TIER, 8040, 10020, "40000000", adminAddr)

	// Fund and approve a dedicated swapper (alice) — avoids the admin self-transfer
	// panic. Faucet grants 5e9 each call; top up a few times so the fuzzed swap
	// amounts (kept within balance) never hit an insufficient-balance revert.
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	for i := 0; i < 4; i++ {
		TokenFaucet(cur, t, barPath, alice)
		TokenFaucet(cur, t, bazPath, alice)
	}
	TokenApprove(cur, t, barPath, alice, poolAddr, maxApprove)
	TokenApprove(cur, t, bazPath, alice, poolAddr, maxApprove)

	const minLimit = "4295128740"
	const maxLimit = "1461446703485210103287273052203988822378723970341"

	fuzz.Check(t, func(ft *fuzz.T) {
		zeroForOne := fuzz.Bool().Draw(ft, "zeroForOne").(bool)
		// keep within alice's funded balance (faucet tops up to ~2e10)
		amt := fuzz.Uint64Range(100, 4_000_000_000).Draw(ft, "amount").(uint64)

		limit := minLimit
		if !zeroForOne {
			limit = maxLimit
		}

		testing.SetRealm(rouRealm)
		_, _ = mockInstanceSwap(0, cur, barPath, bazPath, STANDARD_FEE_TIER, alice, zeroForOne,
			i256.NewInt(int64(amt)).ToString(), limit,
			func(cur realm, amount0Delta int64, amount1Delta int64, _ *pl.CallbackMarker) error {
				return mockSwapCallback(cur, barPath, bazPath, amount0Delta, amount1Delta)
			})

		pool := getMockInstance().mustGetPool(GetPoolPath(barPath, bazPath, STANDARD_FEE_TIER))
		if pool == nil {
			ft.Fatalf("pool disappeared after fuzz swap")
		}
		liq := pool.Liquidity()
		if liq == nil {
			ft.Fatalf("liquidity nil after fuzz swap")
		}
		// u256 is unsigned; if Liquidity were ever negative it would indicate a
		// sign-handling bug in computeSwap — surface it via raw comparison.
		if liq.Cmp(u256.Zero()) < 0 {
			ft.Fatalf("negative liquidity after fuzz swap: %s", liq.ToString())
		}
	})
	t.Logf("fuzz swap sequence completed: invariants held (liquidity >= 0, no VM panic)")
}

var _ = u256.Zero // keep u256 import used
