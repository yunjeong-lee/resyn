{-# LANGUAGE TupleSections #-}

-- | The parser for Synquid's program specification DSL.
module Synquid.Parser where

import Synquid.Logic
import Synquid.Tokens
import Synquid.Program
import Synquid.Util

import Data.Char
import Data.List
import Data.Map (Map, (!), elems, fromList)

import Control.Applicative hiding ((<|>), many)

import Text.Parsec
import qualified Text.Parsec.Token as Token
import Text.Parsec.Expr
import qualified Text.Parsec.Char as Char
import Text.Parsec ((<|>), (<?>))

import Text.Printf

{- Interface -}

type Parser = Parsec String ()

parseProgram :: Parser ProgramAst
parseProgram = whiteSpace *> many parseDeclaration <* eof

testParse :: Parser a -> String -> Either String a
testParse parser str = case parse parser "" str of
  Left err -> Left $ show err
  Right parsed -> Right parsed

{- Lexical analysis -}

opNames :: [String]
opNames = elems unOpTokens ++ (elems binOpTokens \\ keywords) ++ otherOps

opStart :: [Char]
opStart = nub (map head opNames)

opLetter :: [Char]
opLetter = nub (concatMap tail opNames)

synquidDef :: Token.LanguageDef st
synquidDef = Token.LanguageDef 
  commentStart
  commentEnd
  commentLine
  False
  (letter <|> oneOf identifierChars)
  (alphaNum <|> oneOf identifierChars)
  (oneOf opStart)
  (oneOf opLetter)
  keywords
  opNames
  True
  
lexer :: Token.TokenParser ()
lexer = Token.makeTokenParser synquidDef    
      
identifier = Token.identifier lexer
reserved = Token.reserved lexer
reservedOp = Token.reservedOp lexer
natural = Token.natural lexer
whiteSpace = Token.whiteSpace lexer
angles = Token.angles lexer
brackets = Token.brackets lexer
parens = Token.parens lexer
braces = Token.braces lexer
comma = Token.comma lexer
commaSep = Token.commaSep lexer
commaSep1 = Token.commaSep1 lexer
dot = Token.dot lexer
      
{- Declarations -}      

parseDeclaration :: Parser Declaration
parseDeclaration = choice [parseTypeDef, parseDataDef, parseMeasureDef, parsePredDef, parseQualifierDef, try parseSynthesisGoal, parseFuncDef] <?> "declaration"

parseTypeDef :: Parser Declaration
parseTypeDef = do
  reserved "type"
  typeName <- parseTypeName
  typeVars <- many parseIdentifier
  reservedOp "="
  typeDef <- parseType
  return $ TypeDecl typeName typeVars typeDef

parseDataDef :: Parser Declaration
parseDataDef = do
  reserved "data"
  typeName <- parseTypeName
  typeParams <- many parseIdentifier
  predParams <- many $ angles parsePredSig
  wfMetricName <- optionMaybe $ reserved "decreases" >> parseIdentifier
  constructors <- option [] (reserved "where" >> many1 parseConstructorSig) 
  return $ DataDecl typeName typeParams predParams wfMetricName constructors  

parseConstructorSig :: Parser ConstructorSig
parseConstructorSig = do
  ctorName <- parseTypeName
  reservedOp "::"
  ctorType <- parseSchema
  return $ ConstructorSig ctorName ctorType

parseMeasureDef :: Parser Declaration
parseMeasureDef = do
  reserved "measure"
  measureName <- parseIdentifier
  reservedOp "::"
  inSort <- parseSort
  reservedOp "->"
  (outSort, post) <- parseRefinedSort <|> ((, ftrue) <$> parseSort)
  return $ MeasureDecl measureName inSort outSort post
  
parsePredDef :: Parser Declaration
parsePredDef = do
  reserved "predicate"
  sig <- parsePredSig
  return $ PredDecl sig
  
parseQualifierDef :: Parser Declaration
parseQualifierDef = do
  reserved "qualifier"
  QualifierDecl <$> braces (commaSep parseFormula)

parseFuncDef :: Parser Declaration
parseFuncDef = do
  funcName <- parseIdentifier
  reservedOp "::"
  FuncDecl funcName <$> parseSchema

parseSynthesisGoal :: Parser Declaration
parseSynthesisGoal = do
  goalId <- parseIdentifier
  reservedOp "="
  goalImpl <- parseImpl
  return $ SynthesisGoal goalId goalImpl
  
{- Types -}

parseSchema :: Parser RSchema
parseSchema = parseForall <|> (Monotype <$> parseType)

parseForall :: Parser RSchema
parseForall = do
  (PredSig p sorts) <- angles parsePredSig
  dot
  sch <- parseSchema
  return $ ForallP p sorts sch

parseType :: Parser RType
parseType = choice [try parseFunctionType, parseUnrefTypeWithArgs, parseTypeAtom] <?> "type"

parseTypeAtom :: Parser RType
parseTypeAtom = choice [
  parens parseType,
  parseScalarRefType,
  parseUnrefTypeNoArgs
  ]
  
parseUnrefTypeNoArgs = do
  baseType <- parseBaseType
  return $ ScalarT baseType ftrue  
  where
    parseBaseType = choice [
      BoolT <$ reserved "Bool",
      IntT <$ reserved "Int",
      (\name -> DatatypeT name [][]) <$> parseTypeName,
      TypeVarT <$> parseIdentifier]
  
parseUnrefTypeWithArgs = do
  name <- parseTypeName
  typeArgs <- many parseTypeAtom
  predArgs <- many (angles parsePredArg)
  return $ ScalarT (DatatypeT name typeArgs predArgs) ftrue    
  
parsePredArg = braces parseFormula <|> (flip Pred [] <$> parseTypeName)
  
parseScalarUnrefType = parseUnrefTypeWithArgs <|> parseUnrefTypeNoArgs
  
parseScalarRefType = braces $ do
  ScalarT baseType _ <- parseScalarUnrefType
  reservedOp "|"
  refinement <- parseFormula
  return $ ScalarT baseType refinement  

parseFunctionType :: Parser RType
parseFunctionType = do
  argId <- option dontCare (try parseArgName)
  argType <- parseUnrefTypeWithArgs <|> parseTypeAtom
  reservedOp "->"
  returnType <- parseType
  return $ FunctionT argId argType returnType
  where
    parseArgName = parseIdentifier <* reservedOp ":"

parseSort :: Parser Sort
parseSort = parseSortWithArgs <|> parseSortAtom 
  where
    parseSortAtom = choice [
      parens parseSort,
      BoolS <$ reserved "Bool",
      IntS <$ reserved "Int",
      VarS <$> parseIdentifier,
      flip DataS [] <$> parseTypeName
      ]
      
    parseSortWithArgs = choice [
      SetS <$> (reserved "Set" >> parseSortAtom),
      do
        typeName <- parseTypeName
        typeParams <- many parseSortAtom
        return $ DataS typeName typeParams
      ]
      
parseRefinedSort :: Parser (Sort, Formula)
parseRefinedSort = braces $ do
  s <- parseSort
  reservedOp "|"
  refinement <- parseFormula
  return (s, refinement)
      
{- Formulas -}     

{-
 - | @Formula@ parsing is broken up into two functions: @parseFormula@ and @parseTerm@. @parseFormula's@ responsible
 - for parsing binary and unary expressions that consist of other @Formula@s, while @parseTerm@ parses everything else
 - (ie literals).
 -}
parseFormula :: Parser Formula
parseFormula = buildExpressionParser exprTable parseTerm <?> "refinement term"
  where
    exprTable = [
      [unary Not, unary Neg, unary Abs],
      [binary Times AssocLeft],
      [binary Plus AssocLeft, binary Minus AssocLeft],
      [binary Eq AssocNone, binary Neq AssocNone, binary Le AssocNone, binary Lt AssocNone, binary Ge AssocNone, binary Gt AssocNone, binary Member AssocNone],
      [binary And AssocLeft, binary Or AssocLeft],
      [binary Implies AssocRight, binary Iff AssocRight]]
    unary op = Prefix (reservedOp (unOpTokens ! op) >> return (Unary op))
    binary op assoc = Infix (reservedOp (binOpTokens ! op) >> return (Binary op)) assoc

parseTerm :: Parser Formula
parseTerm = try parseAppTerm <|> parseAtomTerm
  where
    parseAppTerm = parsePredApp <|> parseMeasureApp
    parseAtomTerm = choice [
        parens parseFormula
      , parseBoolLit
      , parseIntLit
      , parseSetLit
      , parseNullaryCons
      , parseVariable
      ]
      
    parseBoolLit = (reserved "False" >> return ffalse) <|> (reserved "True" >> return ftrue)
    parseIntLit = IntLit <$> natural
    parseSetLit = SetLit UnknownS <$> brackets (commaSep parseFormula)
    parseNullaryCons = flip (Cons UnknownS) [] <$> parseTypeName
    parseVariable = Var UnknownS <$> parseIdentifier 
    parsePredApp = do
      name <- parseTypeName
      args <- many1 parseAtomTerm
      return $ Pred name args
    parseMeasureApp = do
      name <- parseIdentifier
      parseAtomTerm >>= return . Measure UnknownS name
      
{- Implementations -}

parseImpl :: Parser UProgram
parseImpl = parseFun <|> parseScalar

parseFun = do
  reservedOp "\\"
  x <- parseIdentifier
  reservedOp "."
  body <- parseImpl
  return $ untyped $ PFun x body

parseScalar = parseLet <|> parseIf <|> parseMatch <|> parseETerm

parseLet = do
  reserved "let"
  x <- parseIdentifier
  reservedOp "="
  e1 <- parseETerm
  reserved "in"
  e2 <- parseScalar
  return $ untyped $ PLet x e1 e2
  
parseMatch = do
  reserved "match"
  scr <- parseETerm
  cases <- many1 parseCase
  return $ untyped $ PMatch scr cases
  where
    parseCase = do
      reservedOp "|"
      ctor <- parseTypeName
      args <- many parseIdentifier
      reservedOp "->"
      body <- parseScalar
      return $ Case ctor args body

parseIf = do
  reserved "if"
  iCond <- parseETerm
  reserved "then"
  iThen <- parseImpl
  reserved "else"
  iElse <- parseImpl
  return $ untyped $ PIf iCond iThen iElse

parseETerm = try parseAppTerm <|> parseFormulaTerm
  where
    parseAppTerm = do
      head <- parseAtomTerm
      args <- many (try parseAtomTerm <|> parens (parseImpl))
      return $ foldl1 (\e1 e2 -> untyped $ PApp e1 e2) (head : args)
    parseAtomTerm = choice [
        parens parseETerm
      , parseHole
      , parseSymbol
      ]
    parseHole = reserved "??" >> return (untyped PHole)
    parseSymbol = (parseIdentifier <|> parseTypeName) >>= (return . untyped . PSymbol)
    parseFormulaTerm = untyped . PFormula <$> braces parseFormula    
      
{- Misc -}

parsePredSig :: Parser PredSig
parsePredSig = do
  predName <- parseTypeName
  reservedOp "::"
  sorts <- parseSort `sepBy1` reservedOp "->"
  return $ PredSig predName (init sorts)

parseIdentifier :: Parser Id
parseIdentifier = try $ do
  name <- identifier
  if isUpper $ head name then unexpected ("capitalized " ++ show name) else return name

parseTypeName :: Parser Id
parseTypeName = try $ do
  name <- identifier
  if not (isUpper $ head name) then unexpected ("non-capitalized " ++ show name) else return name
