# Simple Exercise Helper

- This contract simplifies the process of redeeming oTokens (such as oBMX, oFVM) paired with other vanilla tokens
  (WETH, WFTM) for the vanilla token, underlying, or for the LP of underlying asset.
- Typically, the `paymentToken` is needed up front for redemption. This contract uses flash loans to eliminate that
  requirement.
- View functions `quoteExerciseProfit`, `quoteExerciseToUnderlying`, and `quoteExerciseLp` are provided to be useful
  both internally and externally for estimations of output and optimal inputs.
- A 0.25% fee is sent to `feeAddress` on each exercise. Fee is adjustable between 0-1%.

## Testing

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

Note that to properly test both branches of our WFTM balance checks in `exercise()` and `exerciseToLp()`, the tests note
that it is easiest to adjust the WFTM threshold values on the specified lines. With these adjustments, all functions,
with the exception of `_safeTransfer`, `_safeTransferFrom`, and `getAmountIn` are 100% covered.

### Test Results

#### Default settings

```
  contract: SimpleExerciseHelperFantomWFTM - 87.7%
    Ownable._checkOwner - 100.0%
    SimpleExerciseHelperFantomWFTM._checkAllowance - 100.0%
    SimpleExerciseHelperFantomWFTM._exerciseAndSwap - 100.0%
    SimpleExerciseHelperFantomWFTM.getAmountsIn - 100.0%
    SimpleExerciseHelperFantomWFTM.quoteExerciseLp - 100.0%
    SimpleExerciseHelperFantomWFTM.quoteExerciseProfit - 100.0%
    SimpleExerciseHelperFantomWFTM.quoteExerciseToUnderlying - 100.0%
    SimpleExerciseHelperFantomWFTM.receiveFlashLoan - 100.0%
    SimpleExerciseHelperFantomWFTM.setFee - 100.0%
    SimpleExerciseHelperFantomWFTM.exerciseToLp - 75.7%
    SimpleExerciseHelperFantomWFTM._safeTransfer - 75.0%
    SimpleExerciseHelperFantomWFTM._safeTransferFrom - 75.0%
    SimpleExerciseHelperFantomWFTM.exercise - 75.0%
    SimpleExerciseHelperFantomWFTM._getAmountIn - 66.7%
```

#### Using alternate values suggested in `test_exercise_helper`

Hits the opposite sides of the `if` statements for 100% total coverage.

```
contract: SimpleExerciseHelperFantomWFTM - 88.4%
    Ownable._checkOwner - 100.0%
    SimpleExerciseHelperFantomWFTM._checkAllowance - 100.0%
    SimpleExerciseHelperFantomWFTM._exerciseAndSwap - 100.0%
    SimpleExerciseHelperFantomWFTM.getAmountsIn - 100.0%
    SimpleExerciseHelperFantomWFTM.quoteExerciseLp - 100.0%
    SimpleExerciseHelperFantomWFTM.quoteExerciseProfit - 100.0%
    SimpleExerciseHelperFantomWFTM.quoteExerciseToUnderlying - 100.0%
    SimpleExerciseHelperFantomWFTM.receiveFlashLoan - 100.0%
    SimpleExerciseHelperFantomWFTM.setFee - 100.0%
    SimpleExerciseHelperFantomWFTM.exercise - 93.8%
    SimpleExerciseHelperFantomWFTM._safeTransfer - 75.0%
    SimpleExerciseHelperFantomWFTM._safeTransferFrom - 75.0%
    SimpleExerciseHelperFantomWFTM._getAmountIn - 66.7%
    SimpleExerciseHelperFantomWFTM.exerciseToLp - 64.6%
```
