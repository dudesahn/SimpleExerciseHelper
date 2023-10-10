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
