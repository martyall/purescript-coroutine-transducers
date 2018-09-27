# purescript-coroutine-transducers

This library adds a transducer layer to [purescript-coroutines](https://github.com/purescript-contrib/purescript-coroutines)
to allow for intermediate processing phases that are effectful. The implementation was taken directly from Mario Blazevic's [Coroutine Pipelines](https://themonadreader.files.wordpress.com/2011/10/issue19.pdf).

## What's the difference anyway?
purescript-coroutines has fine grained control over the behaviour of the coroutines based on the types. For example, the `CoTransformer` type signature dictates that the coroutine must emit a value before pausing to wait for new ones. This is really nice for dictating behaviour, but it has some annoying consequences:

1. You need to write a fuse operator for each permissable pair of coroutines, which turns out to be a lot. Moreover, because of the deterministic and non-deterministic fuse operators, the number is actually double.
2. None of the intermediate coroutine operators (`Transformer` and `CoTranstransformer`) allow you to terminate based on the received value. This is often useful when the intermediate coroutines are not pure functions.
3. To my knowledge, you cannot write an impure intermediate coroutine at all (aside from using `lift` trivially), but maybe I just don't understand. For example, try to write `transformM` from this library as a `Transformer`.

## Interacting with purescript-coroutines
There are several functions to translate back and forth between things defined in the original library. There are no real tests yet, but the examples from the purescript-coroutines test module are reimplemented here and behave the same way.

