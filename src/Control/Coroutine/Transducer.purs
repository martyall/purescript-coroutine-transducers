module Control.Coroutine.Transducer
  ( Transducer
  , fuse, (.|)
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
  ) where

import Prelude
import Control.Monad.Free.Trans (FreeT, freeT, resume, bimapFreeT)
import Data.Functor.Coproduct (Coproduct(..), left, right)
import Data.Maybe (Maybe(..), maybe)
import Data.Tuple (Tuple(..))
import Data.Either (Either(..))
import Control.Monad.Rec.Class (class MonadRec, tailRecM, Step(..))
import Control.Parallel (class Parallel, parallel, sequential)
import Control.Monad.Trans.Class (lift)
import Control.Coroutine (Consumer, Producer, Emit(..), Await(..))
import Partial.Unsafe (unsafePartial)
import Data.Traversable (traverse_)


type Transducer i o m r = FreeT (Coproduct ((->) (Maybe i)) (Tuple o)) m r

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
    proceed (Left x) (Right (Coproduct (Left f))) = resume (pure x `fuse` f Nothing)
    proceed (Left x) (Left y) = pure <<< Left $ (Tuple x y)

infixr 2 fuse as .|

awaitT :: forall i o m. Monad m => Transducer i o m (Maybe i)
awaitT = freeT $ \_ -> pure <<< Right $ (left pure)

awaitForever :: forall i o m r. Monad m => (i -> Transducer i o m r) -> Transducer i o m Unit
awaitForever send = loop do
  mi <- awaitT
  case mi of
    Nothing -> pure $ Just unit
    Just i -> send i $> Nothing

yieldT :: forall i o m. Monad m => o -> Transducer i o m Unit
yieldT o = freeT $ \_ -> pure <<< Right $ (right $ Tuple o (pure unit))

transform :: forall i o m. Monad m => (i -> o) -> Transducer i o m Unit
transform f = transformM (pure <<< f)

transformM :: forall i o m. Monad m => (i -> m o) -> Transducer i o m Unit
transformM f = do
  mi <- awaitT
  maybe (pure unit) (\i -> lift (f i) >>= yieldT) mi

--------------------------------------------------------------------------------
-- | State
--------------------------------------------------------------------------------

liftStateless :: forall i o m. Monad m => (i -> Array o) -> Transducer i o m Unit
liftStateless f = do
  mi <- awaitT
  maybe (pure unit) (\i -> traverse_ yieldT (f i) >>= \_ -> liftStateless f) mi

liftStateful :: forall i o m s. Monad m => (s -> i -> Tuple s (Array o)) -> (s -> Array o) -> s -> Transducer i o m Unit
liftStateful f eof s = do
  mi <- awaitT
  maybe (traverse_ yieldT (eof s)) (\i -> let Tuple s' bs = f s i
                                          in traverse_ yieldT bs >>= \_ -> liftStateful f eof s') mi

--------------------------------------------------------------------------------
-- | Interactions with Control.Coroutine
--------------------------------------------------------------------------------

fromProducer :: forall m o r. Monad m => Producer o m r -> Transducer Void o m r
fromProducer = bimapFreeT (\(Emit o a) -> right $ Tuple o a) identity

toProducer :: forall m o r. Monad m => Transducer Void o m r -> Producer o m r
toProducer = bimapFreeT (unsafePartial $ case _ of
  Coproduct (Right (Tuple o a)) -> Emit o a) identity

fromConsumer :: forall m i r. Monad m => Consumer (Maybe i) m r -> Transducer i Void m r
fromConsumer = bimapFreeT (\(Await f) -> left f) identity

toConsumer :: forall m i r. Monad m => Transducer i Void m r -> Consumer (Maybe i) m r
toConsumer = bimapFreeT (unsafePartial $ case _ of
  Coproduct (Left f) -> Await f) identity

--------------------------------------------------------------------------------
-- | Helper Functions
--------------------------------------------------------------------------------

-- | Loop until the computation returns a `Just`.
loop :: forall f m a. Functor f => Monad m => FreeT f m (Maybe a) -> FreeT f m a
loop me = tailRecM (\_ -> map (maybe (Loop unit) Done) me) unit
