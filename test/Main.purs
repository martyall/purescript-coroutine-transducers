module Test.Main where

import Prelude

import Control.Coroutine (($$), ($~), (~$), (/\))
import Control.Coroutine as Co
import Control.Coroutine.Transducer as T
import Control.Monad.Rec.Class (forever)
import Control.Monad.Trans.Class (lift)
import Data.Maybe (Maybe(..))
import Data.Newtype (wrap)
import Effect (Effect)
import Effect.Aff (Aff, delay, launchAff)
import Effect.Class (liftEffect)
import Effect.Console (log)

nats :: Co.Producer Int Aff Unit
nats = go 0
  where
  go i = do
    Co.emit i
    lift (delay (wrap 10.0)) -- 10ms delay
    go (i + 1)

printer :: Co.Consumer (Maybe String) Aff Unit
printer = forever do
  ms <- Co.await
  case ms of
    Nothing -> pure Nothing
    Just s -> do
      lift (liftEffect (log s))
      pure Nothing

showing :: forall a m. Show a => Monad m => Co.Transformer a String m Unit
showing = forever (Co.transform show)

coshowing :: Co.CoTransformer String Int Aff Unit
coshowing = go 0
  where
  go i = do
    o <- Co.cotransform i
    lift (liftEffect (log o))
    go (i + 1)

main :: Effect Unit
main = void $ launchAff do
  Co.runProcess ((nats $~ Co.composeTransformers showing (Co.transform Just)) $$ printer)
  void $ Co.runProcess ( T.toProcess $ (
                  T.fromProducer nats T.=>=
                  T.fromTransformer showing T.=>=
                  T.fromConsumer printer
                  )
                )
  Co.runProcess (nats /\ nats $$ Co.composeTransformers showing (forever $ Co.transform Just) ~$ printer)
  void $ Co.runProcess (T.toProcess $ (
                    T.fromProducer (nats /\ nats) T.=>=
                    T.fromTransformer showing T.=>=
                    T.fromConsumer printer
                    )
                )
