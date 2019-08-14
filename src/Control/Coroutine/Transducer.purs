module Control.Coroutine.Transducer
  ( Transducer
  , fuse, (=>=)
  , awaitT
  , awaitForever
  , yieldT
  , transform
  , transformM
  , liftStateless
  , liftStateful
  , fromProducer
  , toProducer
  , fromConsumer
  , toConsumer
  , fromTransformer
  , fromCoTransformer
  , toProcess
  ) where

import Prelude

import Control.Coroutine (Await(..), Co, CoTransform(..), CoTransformer, Consumer, Emit(..), Process, Producer, Transform(..), Transformer, loop)
import Control.Monad.Free.Trans (freeT, interpret, resume)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.Trans.Class (lift)
import Control.Parallel (class Parallel, parallel, sequential)
import Data.Either (Either(..), either)
import Data.Functor.Coproduct (Coproduct(..), left, right)
import Data.Maybe (Maybe(..), maybe)
import Data.Traversable (traverse_)
import Data.Tuple (Tuple(..))
import Partial.Unsafe (unsafePartial)
import Unsafe.Coerce (unsafeCoerce)


type Transducer i o = Co (Coproduct ((->) (Maybe i)) (Tuple o))

-- | The `fuse` operator runs an upstream and downstream `Transducer` in parallel. In the event that
-- | the upstream pauses with an emit statement and the downstream with an await statement,
-- | data is passed downstream and the computation resumed. In the event that they have both terminated,
-- | we return both termination and terminate. Otherwise we build a continuation which can be resumed later
-- | and makes use of the accumulated state.
fuse
  :: forall a b c m par x y.
     MonadRec m
  => Parallel par m
  => Transducer a b m x
  -> Transducer b c m y
  -> Transducer a c m (Tuple x y)
fuse t1 t2 = freeT \_ -> go (Tuple t1 t2)
  where
    go (Tuple t t') = do
      Tuple tnext tnext' <-
        sequential (Tuple <$> parallel (resume t)
                          <*> parallel (resume t'))
      proceed tnext tnext'
    proceed (Right (Coproduct (Left f))) c = pure (Right $ left $ map (_ `fuse` (freeT $ \_ -> pure c)) f)
    proceed c (Right (Coproduct (Right s))) = pure (Right $ right $ map (fuse $ freeT $ \_ -> pure c) s)
    proceed (Right (Coproduct (Right (Tuple o next)))) (Right (Coproduct (Left f))) = resume (next `fuse` f (Just o))
    proceed (Right (Coproduct (Right (Tuple o next)))) (Left y) = resume (next `fuse` pure y)
    proceed (Left z) (Right (Coproduct (Left f))) = resume (pure z `fuse` f Nothing)
    proceed (Left x) (Left y) = pure <<< Left $ (Tuple x y)

infixr 2 fuse as =>=

-- | Await an upstream value.
awaitT :: forall i o m. Monad m => Transducer i o m (Maybe i)
awaitT = freeT $ \_ -> pure <<< Right $ (left pure)

-- | Continue waiting for upstream values, while never returning.
awaitForever :: forall i o m r. Monad m => (i -> Transducer i o m r) -> Transducer i o m Unit
awaitForever send = loop do
  mi <- awaitT
  case mi of
    Nothing -> pure $ Just unit
    Just i -> send i $> Nothing

-- | Yield a value to downstream
yieldT :: forall i o m. Monad m => o -> Transducer i o m Unit
yieldT o = freeT $ \_ -> pure <<< Right $ (right $ Tuple o (pure unit))

-- | Create a `Transducer` from a pure function.
transform :: forall i o m. Monad m => (i -> o) -> Transducer i o m Unit
transform f = transformM (pure <<< f)

-- | Create a `Transducer` from an effectful function.
transformM :: forall i o m. Monad m => (i -> m o) -> Transducer i o m Unit
transformM f = do
  mi <- awaitT
  maybe (pure unit) (\i -> lift (f i) >>= yieldT) mi

--------------------------------------------------------------------------------
--  Stateful pipelines
--------------------------------------------------------------------------------

liftStateless :: forall i o m. Monad m => (i -> Array o) -> Transducer i o m Unit
liftStateless f = do
  mi <- awaitT
  maybe (pure unit) (\i -> traverse_ yieldT (f i) >>= \_ -> liftStateless f) mi

-- | Transform values according to an accumulated state `s`.
liftStateful :: forall i o m s. Monad m => (s -> i -> Tuple s (Array o)) -> (s -> Array o) -> s -> Transducer i o m Unit
liftStateful f eof s = do
  mi <- awaitT
  maybe (traverse_ yieldT (eof s)) (\i -> let Tuple s' bs = f s i
                                          in traverse_ yieldT bs >>= \_ -> liftStateful f eof s') mi

--------------------------------------------------------------------------------
-- Interactions with Control.Coroutine `Producer`s and `Consumer`s
--------------------------------------------------------------------------------

fromProducer :: forall m o r. Monad m => Producer o m r -> Transducer Void o m r
fromProducer = interpret (\(Emit o a) -> right $ Tuple o a)

toProducer :: forall m o r. Monad m => Transducer Void o m r -> Producer o m r
toProducer = interpret (unsafePartial $ case _ of
  Coproduct (Right (Tuple o a)) -> Emit o a)

fromConsumer :: forall m i r. Monad m => Consumer (Maybe i) m r -> Transducer i Void m r
fromConsumer = interpret (\(Await f) -> left f)

toConsumer :: forall m i r. Monad m => Transducer i Void m r -> Consumer (Maybe i) m r
toConsumer = interpret (unsafePartial $ case _ of
  Coproduct (Left f) -> Await f)

fromTransformer :: forall i o m x. MonadRec m => Transformer i o m x -> Transducer i o m Unit
fromTransformer t = do
    a <- lift $ resume t
    either (const $ pure unit) go a
  where
   go (Transform f) = do
     mi <- awaitT
     case mi of
       Nothing -> pure unit
       Just i -> do
         let Tuple o k = f i
         yieldT o
         fromTransformer k

fromCoTransformer :: forall i o m x. MonadRec m => CoTransformer i o m x -> Transducer i o m Unit
fromCoTransformer t = do
    a <- lift $ resume t
    either (const $ pure unit) go a
  where
    go (CoTransform o f) = do
      yieldT o
      mi <- awaitT
      maybe (pure unit) (fromCoTransformer <<< f) mi

toProcess :: forall m x. Functor m => Transducer Void Void m x -> Process m x
toProcess = interpret (unsafeCoerce unit)
