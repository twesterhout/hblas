{-# LANGUAGE BangPatterns , RankNTypes, GADTs #-}


module Numerical.HBLAS.BLAS where
--(
--    dgemm
--    ,sgemm
--    ,cgemm
--    ,zgemm) 


import Numerical.HBLAS.UtilsFFI    
import Numerical.HBLAS.BLAS.FFI 
import Numerical.HBLAS.MatrixTypes
import Control.Monad.Primitive
import Data.Complex 
import qualified Data.Vector.Storable.Mutable as SM

--
flopsThreshold = 10000
gemmComplexity a b c = a * b * c  -- this will be wrong by some constant factor, albeit a small one


-- this covers the ~6 cases for checking the dimensions for GEMM quite nicely
isBadGemm tra trb  ax ay bx by cx cy = isBadGemmHelper (cds tra (ax,ay)) (cds trb (bx,by) )  (cx,cy)
    where 
    cds = coordSwapper 
    isBadGemmHelper !(ax,ay) !(bx,by) !(cx,cy) =  (minimum [ax, ay, bx, by, cx ,cy] <= 0)  
        || not (  cy ==  ay && cx == bx && ax == by)

coordSwapper :: Transpose -> (a,a)-> (a,a)
coordSwapper NoTranspose (a,b) = (a,b)
coordSwapper ConjNoTranspose (a,b) = (a,b) 
coordSwapper Transpose (a,b) = (b,a)
coordSwapper ConjTranspose (a,b) = (b,a)


encodeNiceOrder :: SOrientation x  -> CBLAS_ORDERT
encodeNiceOrder SRow= encodeOrder  BLASRowMajor
encodeNiceOrder SColumn= encodeOrder BLASColMajor


encodeFFITranspose :: Transpose -> CBLAS_TRANSPOSET
encodeFFITranspose  x=  encodeTranspose $ encodeNiceTranspose x 

encodeNiceTranspose :: Transpose -> BLAS_Transpose
encodeNiceTranspose x = case x of 
        NoTranspose -> BlasNoTranspose
        Transpose -> BlasTranspose
        ConjTranspose -> BlasConjTranspose
        ConjNoTranspose -> BlasConjNoTranspose

--data BLAS_Transpose = BlasNoTranspose | BlasTranspose | BlasConjTranspose | BlasConjNoTranspose 
--data Transpose = NoTranspose | Transpose | ConjTranspose | ConjNoTranspose


type GemmFun el orient s m = Transpose ->Transpose ->  el -> el  -> MDenseMatrix s orient el
  ->   MDenseMatrix s orient el  ->  MDenseMatrix s orient el -> m ()


{-
A key design goal of this ffi is to provide *safe* throughput guarantees 
for a concurrent application built on top of these apis, while evading
any overheads for providing such safety. Accordingly, on inputs sizes

-}


---- |  Matrix mult for general dense matrices
--type GemmFunFFI scale el = CBLAS_ORDERT ->   CBLAS_TRANSPOSET -> CBLAS_TRANSPOSET->
        --CInt -> CInt -> CInt -> {- scal A * B -} scale  -> {- Matrix A-} Ptr el  -> CInt -> {- B -}  Ptr el -> CInt-> 
            --scale -> {- C -}  Ptr el -> CInt -> IO ()
--type GemmFun = MutDenseMatrix or el ->  MutDenseMatrix or el ->   MutDenseMatrix or el -> m ()

{-# NOINLINE gemmAbstraction #-}
gemmAbstraction:: (SM.Storable el, PrimMonad m) =>  String -> 
    GemmFunFFI scale el -> GemmFunFFI scale el -> (el -> (scale -> m ())->m ()) -> forall orient . GemmFun el orient (PrimState m) m 
gemmAbstraction gemmName gemmSafeFFI gemmUnsafeFFI constHandler = go 
  where 
    shouldCallFast :: Int -> Int -> Int -> Bool                         
    shouldCallFast cy cx ax = flopsThreshold >= gemmComplexity cy cx ax

    go  tra trb  alpha beta 
        (MutableDenseMatrix ornta ax ay astride abuff) 
        (MutableDenseMatrix _ bx by bstride bbuff) 
        (MutableDenseMatrix _ cx cy cstride cbuff) 
            |  isBadGemm tra trb  ax ay bx by cx cy = error $! "bad dimension args to GEMM: ax ay bx by cx cy: " ++ show [ax, ay, bx, by, cx ,cy]
            | SM.overlaps abuff cbuff || SM.overlaps bbuff cbuff = 
                    error $ "the read and write inputs for: " ++ gemmName ++ " overlap. This is a programmer error. Please fix." 
            | otherwise  = 
                {-  FIXME : Add Sharing check that also errors out for now-}
                unsafeWithPrim abuff $ \ap -> 
                unsafeWithPrim bbuff $ \bp ->  
                unsafeWithPrim cbuff $ \cp  -> 
                constHandler alpha $  \alphaPtr ->   
                constHandler beta $ \betaPtr ->  
                    do  (ax,ay) <- return $ coordSwapper tra (ax,ay)
                        --- dont need to swap b, info is in a and c
                        --- c doesn't get implicitly transposed
                        blasOrder <- return $ encodeNiceOrder ornta -- all three are the same orientation
                        rawTra <- return $  encodeFFITranspose tra 
                        rawTrb <- return $   encodeFFITranspose trb
                                 -- example of why i want to switch to singletones
                        unsafePrimToPrim $!  (if shouldCallFast cy cx ax then gemmUnsafeFFI  else gemmSafeFFI ) 
                            blasOrder rawTra rawTrb (fromIntegral cy) (fromIntegral cx) (fromIntegral ax) 
                                alphaPtr ap  (fromIntegral astride) bp (fromIntegral bstride) betaPtr  cp (fromIntegral cstride)


{-pureGemm :: PrimMonad m=>
(Transpose ->Transpose ->  el -> el  -> MutDenseMatrix (PrimState m) orient el
      ->   MutDenseMatrix (PrimState m) orient el  ->  
                                    MutDenseMatrix (PrimState m) orient el -> m ())->
  Transpose ->Transpose ->  el -> el  -> DenseMatrix  orient el
  ->   DenseMatrix  orient el  ->  DenseMatrix  orient el  -}

sgemm :: PrimMonad m=> 
     Transpose ->Transpose ->  Float -> Float  -> MDenseMatrix (PrimState m) orient Float
  ->   MDenseMatrix (PrimState m) orient Float  ->  MDenseMatrix (PrimState m) orient Float -> m ()
sgemm =  gemmAbstraction "sgemm" cblas_sgemm_unsafe cblas_sgemm_safe (\x f -> f x )                                 
                        

dgemm :: PrimMonad m=> 
     Transpose ->Transpose ->  Double -> Double -> MDenseMatrix (PrimState m) orient Double
  ->   MDenseMatrix (PrimState m) orient Double   ->  MDenseMatrix (PrimState m) orient Double -> m ()
dgemm = gemmAbstraction "dgemm" cblas_dgemm_unsafe cblas_dgemm_safe (\x f -> f x )    
 

cgemm :: PrimMonad m=>  Transpose ->Transpose ->  (Complex Float) -> (Complex Float)  -> 
        MDenseMatrix (PrimState m) orient (Complex Float)  ->   
        MDenseMatrix (PrimState m) orient (Complex Float)  ->  
        MDenseMatrix (PrimState m) orient (Complex Float) -> m ()
cgemm = gemmAbstraction "cgemm" cblas_cgemm_unsafe cblas_cgemm_safe withRStorable_                                

zgemm :: PrimMonad m=>  Transpose ->Transpose ->  (Complex Double) -> (Complex Double )  -> 
        MDenseMatrix (PrimState m) orient (Complex Double )  ->   
        MDenseMatrix (PrimState m) orient (Complex Double)  ->  
        MDenseMatrix (PrimState m) orient (Complex Double) -> m ()
zgemm = gemmAbstraction "zgemm" cblas_zgemm_unsafe cblas_zgemm_safe withRStorable_  