module Control.Coroutine.Transducer
  ( Transducer
  , Transduce
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
import Data.These (These(..))
import Data.Traversable (traverse_)
import Data.Tuple (Tuple(..))
import Partial.Unsafe (unsafePartial)
import Unsafe.Coerce (unsafeCoerce)


type Transduce i o = Coproduct (Function (Maybe i)) (Tuple o)


type Transducer i o = Co (Transduce i o)

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
fuse t1 t2 = freeT \_ -> go t1 t2
  where
    go t1' t2' = join $ sequential $ ado
      a <- parallel $ resume t1'
      b <- parallel $ resume t2'
      in proceed a b

    proceed   (Right (Coproduct (Left f)))               c@(Right (Coproduct (Right _)))     = pure $ Right $ left  $ f <#> flip fuse (freeT $ \_ -> pure c)
    proceed   (Right (Coproduct (Left f)))               c@(Right (Coproduct (Left _)))      = pure $ Right $ left  $ f <#> flip fuse (freeT $ \_ -> pure c)
    proceed   (Right (Coproduct (Left f)))               c@(Left _)                          = pure $ Right $ left  $ f <#> flip fuse (freeT $ \_ -> pure c)
    proceed c@(Left _)                                     (Right (Coproduct (Right s)))     = pure $ Right $ right $ fuse (freeT $ \_ -> pure c) <$> s
    proceed c@(Right (Coproduct (Right (Tuple _ _))))      (Right (Coproduct (Right s)))     = pure $ Right $ right $ fuse (freeT $ \_ -> pure c) <$> s
    proceed   (Right (Coproduct (Right (Tuple o next))))   (Right (Coproduct (Left f)))      = resume $ next `fuse` f (Just o)
    proceed   (Right (Coproduct (Right (Tuple o next))))   (Left y)                          = resume $ next `fuse` pure y
    proceed   (Left x)                                     (Right (Coproduct (Left f)))      = resume $ pure x `fuse` f Nothing
    proceed   (Left x)                                     (Left y)                          = pure $ Left $ (Tuple x y)

fuseT
  :: forall a b c m par x y.
     MonadRec m
  => Parallel par m
  => Transducer a b m x
  -> Transducer b c m y
  -> Transducer a c m (These x y)
fuseT t1 t2 = freeT \_ -> go t1 t2
  where
    go t1' t2' = join $ sequential $ ado
      a <- parallel $ resume t1'
      b <- parallel $ resume t2'
      in proceed a b

    proceed   (Right (Coproduct (Left f)))               c@(Right (Coproduct (Right _)))     = pure $ Right $ left  $ f <#> flip fuseT (freeT $ \_ -> pure c)
    proceed   (Right (Coproduct (Left f)))               c@(Right (Coproduct (Left _)))      = pure $ Right $ left  $ f <#> flip fuseT (freeT $ \_ -> pure c)
    proceed   (Right (Coproduct (Left f)))                 (Left y)                          = pure $ Left $ That y
    proceed   (Left x)                                     (Right (Coproduct (Right s)))     = pure $ Left $ This x
    proceed c@(Right (Coproduct (Right (Tuple _ _))))      (Right (Coproduct (Right s)))     = pure $ Right $ right $ fuseT (freeT $ \_ -> pure c) <$> s
    proceed   (Right (Coproduct (Right (Tuple o next))))   (Right (Coproduct (Left f)))      = resume $ next `fuseT` f (Just o)
    proceed   (Right (Coproduct (Right (Tuple o next))))   (Left y)                          = pure $ Left $ That y
    proceed   (Left x)                                     (Right (Coproduct (Left f)))      = pure $ Left $ This x
    proceed   (Left x)                                     (Left y)                          = pure $ Left $ Both x y

infixr 2 fuse as =>=

fuseL
  :: forall a b c m x y.
     MonadRec m
  => Transducer a b m x
  -> Transducer b c m y
  -> Transducer a c m x
fuseL t1 t2 = freeT \_ -> go t1 t2
  where
    go t1' t2' = do
      a <- resume t1'
      case a of
        Left x -> pure $ Left x 
        Right x -> do
          b <- resume t2'
          proceed x b

    proceed   (Coproduct (Left f))               c@(Right (Coproduct (Right _)))     = pure $ Right $ left  $ f <#> flip fuseL (freeT $ \_ -> pure c)
    proceed   (Coproduct (Left f))               c@(Right (Coproduct (Left _)))      = pure $ Right $ left  $ f <#> flip fuseL (freeT $ \_ -> pure c)
    proceed   (Coproduct (Left f))               c@(Left _)                          = pure $ Right $ left  $ f <#> flip fuseL (freeT $ \_ -> pure c)
    proceed c@(Coproduct (Right (Tuple _ _)))      (Right (Coproduct (Right s)))     = pure $ Right $ right $ fuseL (freeT $ \_ -> pure $ Right c) <$> s
    proceed   (Coproduct (Right (Tuple o next)))   (Right (Coproduct (Left f)))      = resume $ next `fuseL` f (Just o)
    proceed   (Coproduct (Right (Tuple o next)))   (Left y)                          = resume $ next `fuseL` pure y


fuseR
  :: forall a b c m x y.
     MonadRec m
  => Transducer a b m x
  -> Transducer b c m y
  -> Transducer a c m y
fuseR t1 t2 = freeT \_ -> go t1 t2
  where
    go t1' t2' = do
      b <- resume t2'
      case b of
        Left y -> pure $ Left y
        Right y -> do
          a <- resume t1'
          proceed a y

    proceed   (Right (Coproduct (Left f)))               c@(Coproduct (Right _))     = pure $ Right $ left  $ f <#> flip fuseR (freeT $ \_ -> pure $ Right c)
    proceed   (Right (Coproduct (Left f)))               c@(Coproduct (Left _))      = pure $ Right $ left  $ f <#> flip fuseR (freeT $ \_ -> pure $ Right c)
    proceed c@(Left _)                                     (Coproduct (Right s))     = pure $ Right $ right $ fuseR (freeT $ \_ -> pure c) <$> s
    proceed c@(Right (Coproduct (Right (Tuple _ _))))      (Coproduct (Right s))     = pure $ Right $ right $ fuseR (freeT $ \_ -> pure c) <$> s
    proceed   (Right (Coproduct (Right (Tuple o next))))   (Coproduct (Left f))      = resume $ next `fuseR` f (Just o)
    proceed   (Left x)                                     (Coproduct (Left f))      = resume $ pure x `fuseR` f Nothing

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
