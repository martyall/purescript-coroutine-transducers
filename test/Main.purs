module Test.Main where

import Prelude

import Control.Coroutine.Transducer as T
import Control.Monad.Rec.Class (class MonadRec, whileJust)
import Control.Parallel (class Parallel)
import Data.Array (range)
import Data.Array as Array
import Data.Foldable (for_)
import Data.Traversable (traverse)
import Data.Tuple (snd)
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay, launchAff)
import Effect.Class (liftEffect)
import Effect.Class.Console (log)
import Test.Assert (assert')

naturals10 :: T.Producer Int Aff Unit
naturals10 = for_ (range 1 10) T.yieldT

delayT :: forall i. Number -> T.Transducer i i Aff Unit
delayT ms = T.transformForever \input ->
  input <$ delay (Milliseconds ms)

foreverPrinter :: String -> T.Transducer String String Aff Unit
foreverPrinter prefix = T.transformForever \input ->
  input <$ log (prefix <> "| " <> input)

drain :: forall i. T.Transducer i Void Aff (Array i)
drain = whileJust $ T.awaitT >>= traverse (Array.singleton >>> pure)

fuse'r
  :: forall a b c m par x y.
     MonadRec m
  => Parallel par m
  => T.Transducer a b m x
  -> T.Transducer b c m y
  -> T.Transducer a c m y
fuse'r a b = T.fuse a b <#> snd

infixr 2 fuse'r as =>=|

main :: Effect Unit
main = void $ launchAff do
  res <- T.runProcess
    $ naturals10
    =>=| delayT 100.0
    =>=| T.awaitForever (show >>> T.yieldT)
    =>=| foreverPrinter "A"
    =>=| delayT 100.0
    =>=| T.awaitForever (show >>> T.yieldT)
    =>=| foreverPrinter "B"
    =>=| drain
  liftEffect $ assert' "test 1 res is valid"
    $ ["\"1\"","\"2\"","\"3\"","\"4\"","\"5\"","\"6\"","\"7\"","\"8\"","\"9\"","\"10\""] == res
