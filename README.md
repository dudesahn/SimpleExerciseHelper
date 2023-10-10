# README

## Simple Exercise Helper

- This contract simplifies the process of redeeming oTokens (such as oBMX, oFVM) paired with other vanilla tokens
  (WETH, WFTM) for the vanilla token, underlying, or for the LP of underlying asset.
- Typically, the `paymentToken` is needed up front for redemption. This contract uses flash loans to eliminate that
  requirement.
- View functions `quoteExerciseProfit`, `quoteExerciseToUnderlying`, and `quoteExerciseLp` are provided to be useful
  both internally and externally for estimations of output and optimal inputs.
- A 0.25% fee is sent to `feeAddress` on each exercise. Fee is adjustable between 0-1%.

### Testing

To run the test suite:

```
brownie test -s
```

To generate a coverage report:

```
brownie test --coverage
```

Then to visualize:

```
brownie gui
```

Note that to properly test both branches of our WETH balance checks in `exercise()` and `exerciseToLp()`, the tests note
that it is easiest to adjust the WETH threshold values on the specified lines. With these adjustments, all functions,
with the exception of `_safeTransfer`, `_safeTransferFrom`, and `getAmountIn` are 100% covered.

### Test Results

#### Default settings

```
  contract: SimpleExerciseHelperBaseWETH - 87.7%
    Ownable._checkOwner - 100.0%
    SimpleExerciseHelperBaseWETH._checkAllowance - 100.0%
    SimpleExerciseHelperBaseWETH._exerciseAndSwap - 100.0%
    SimpleExerciseHelperBaseWETH.getAmountsIn - 100.0%
    SimpleExerciseHelperBaseWETH.quoteExerciseLp - 100.0%
    SimpleExerciseHelperBaseWETH.quoteExerciseProfit - 100.0%
    SimpleExerciseHelperBaseWETH.quoteExerciseToUnderlying - 100.0%
    SimpleExerciseHelperBaseWETH.receiveFlashLoan - 100.0%
    SimpleExerciseHelperBaseWETH.setFee - 100.0%
    SimpleExerciseHelperBaseWETH.exerciseToLp - 75.7%
    SimpleExerciseHelperBaseWETH._safeTransfer - 75.0%
    SimpleExerciseHelperBaseWETH._safeTransferFrom - 75.0%
    SimpleExerciseHelperBaseWETH.exercise - 75.0%
    SimpleExerciseHelperBaseWETH._getAmountIn - 66.7%
```

#### Using alternate values suggested in `test_exercise_helper`

Hits the opposite sides of the `if` statements for 100% total coverage.

```
  contract: SimpleExerciseHelperBaseWETH - 88.4%
    Ownable._checkOwner - 100.0%
    SimpleExerciseHelperBaseWETH._checkAllowance - 100.0%
    SimpleExerciseHelperBaseWETH._exerciseAndSwap - 100.0%
    SimpleExerciseHelperBaseWETH.getAmountsIn - 100.0%
    SimpleExerciseHelperBaseWETH.quoteExerciseLp - 100.0%
    SimpleExerciseHelperBaseWETH.quoteExerciseProfit - 100.0%
    SimpleExerciseHelperBaseWETH.quoteExerciseToUnderlying - 100.0%
    SimpleExerciseHelperBaseWETH.receiveFlashLoan - 100.0%
    SimpleExerciseHelperBaseWETH.setFee - 100.0%
    SimpleExerciseHelperBaseWETH.exercise - 93.8%
    SimpleExerciseHelperBaseWETH._safeTransfer - 75.0%
    SimpleExerciseHelperBaseWETH._safeTransferFrom - 75.0%
    SimpleExerciseHelperBaseWETH._getAmountIn - 66.7%
    SimpleExerciseHelperBaseWETH.exerciseToLp - 64.6%

```
