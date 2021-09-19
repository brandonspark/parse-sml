(** Copyright (c) 2021 Sam Westrick
  *
  * See the file LICENSE for details.
  *)

structure ParseAllSMLFromMLB:
sig
  (** Take an .mlb source and fully parse all SML by loading all filepaths
    * recursively specified by the .mlb and parsing them, etc.
    *)
  val parse: MLtonPathMap.t -> FilePath.t -> Ast.t
  val readSMLPathsFromMLB: MLtonPathMap.t -> FilePath.t -> FilePath.t Seq.t
end =
struct

  fun readSMLPathsFromMLB pathmap mlbPath : FilePath.t Seq.t =
    let
      open MLBAst

      fun expandAndJoin relativeDir path =
        let
          val path = MLtonPathMap.expandPath pathmap path
        in
          if FilePath.isAbsolute path then
            path
          else
            FilePath.normalize (FilePath.join (relativeDir, path))
        end


      fun doBasdec parents relativeDir basdec =
        case basdec of
          DecMultiple {elems, ...} =>
            Seq.flatten (Seq.map (doBasdec parents relativeDir) elems)
        | DecPathMLB {path, token} =>
            (doMLB parents relativeDir path
            handle OS.SysErr (msg, _) =>
              let
                val path = expandAndJoin relativeDir path
                val backtrace =
                  "Included from: " ^ String.concatWith " -> "
                    (List.rev (List.map FilePath.toUnixPath parents))
              in
                ParserUtils.error
                  { pos = MLBToken.getSource token
                  , what = (msg ^ ": " ^ FilePath.toUnixPath path)
                  , explain = SOME backtrace
                  }
              end)
        | DecPathSML {path, ...} =>
            Seq.singleton (expandAndJoin relativeDir path)
        | DecBasis {elems, ...} =>
            Seq.flatten (Seq.map (doBasexp parents relativeDir o #basexp) elems)
        | DecLocalInEnd {basdec1, basdec2, ...} =>
            Seq.append
              (doBasdec parents relativeDir basdec1, doBasdec parents relativeDir basdec2)
        | DecAnn {basdec, ...} =>
            doBasdec parents relativeDir basdec
        | _ => Seq.empty ()

      and doBasexp parents relativeDir basexp =
        case basexp of
          BasEnd {basdec, ...} => doBasdec parents relativeDir basdec
        | LetInEnd {basdec, basexp, ...} =>
            Seq.append
              ( doBasdec parents relativeDir basdec
              , doBasexp parents relativeDir basexp
              )
        | _ => Seq.empty ()

      and doMLB parents relativeDir mlbPath =
        let
          val path = expandAndJoin relativeDir mlbPath
          val _ = print ("loading " ^ FilePath.toUnixPath path ^ "\n")
          val mlbSrc = Source.loadFromFile path
          val Ast basdec = MLBParser.parse mlbSrc
        in
          doBasdec (path :: parents) (FilePath.dirname path) basdec
        end

    in
      doMLB [] (FilePath.fromUnixPath ".") mlbPath
    end


  (***************************************************************************
   ***************************************************************************
   ***************************************************************************)


  structure VarKey =
  struct
    type t = Token.t
    fun compare (tok1, tok2) =
      String.compare (Token.toString tok1, Token.toString tok2)
  end

  structure FilePathKey =
  struct
    type t = FilePath.t
    fun compare (fp1, fp2) =
      String.compare (FilePath.toUnixPath fp1, FilePath.toUnixPath fp2)
  end

  structure VarDict = Dict (VarKey)
  structure FilePathDict = Dict (FilePathKey)

  (** For the purposes of parsing, we only need to remember infix definitions
    * across source files.
    *
    * TODO: FIX: a basis also needs to be explicit about what it has set nonfix!
    * (When merging bases, if the second basis sets an identifier nonfix, then
    * the previous basis infix is overridden.)
    *)
  type basis =
    {fixities: InfixDict.t}

  val emptyBasis = {fixities = InfixDict.empty}

  fun mergeBases (b1: basis, b2: basis) =
    {fixities = InfixDict.union (#fixities b1, #fixities b2)}

  type context =
    { parents: FilePath.t list
    , dir: FilePath.t
    (*, mlbs: basis FilePathDict.t
    , bases: basis VarDict.t *)
    }


  fun parse pathmap mlbPath : Ast.t =
    let
      open MLBAst

      fun expandAndJoin relativeDir path =
        let
          val path = MLtonPathMap.expandPath pathmap path
        in
          if FilePath.isAbsolute path then
            path
          else
            FilePath.normalize (FilePath.join (relativeDir, path))
        end


      fun fileErrorHandler ctx path token errorMessage =
        let
          val path = expandAndJoin (#dir ctx) path
          val backtrace =
            "Included from: " ^ String.concatWith " -> "
              (List.rev (List.map FilePath.toUnixPath (#parents ctx)))
        in
          ParserUtils.error
            { pos = MLBToken.getSource token
            , what = (errorMessage ^ ": " ^ FilePath.toUnixPath path)
            , explain = SOME backtrace
            }
        end


      fun doSML ctx (basis, path, errFun) =
        let
          val path = expandAndJoin (#dir ctx) path

          val _ = print ("loading " ^ FilePath.toUnixPath path ^ "\n")
          val src =
            Source.loadFromFile path
            handle OS.SysErr (msg, _) => errFun msg

          val (infdict, ast) = Parser.parseWithInfdict (#fixities basis) src
        in
          ({fixities = infdict}, ast)
        end


      fun doMLB ctx (basis, path, errFun) =
        let
          val path = expandAndJoin (#dir ctx) path

          val _ = print ("loading " ^ FilePath.toUnixPath path ^ "\n")
          val mlbSrc =
            Source.loadFromFile path
            handle OS.SysErr (msg, _) => errFun msg

          val Ast basdec = MLBParser.parse mlbSrc

          val ctx' =
            { parents = path :: #parents ctx
            , dir = FilePath.dirname path
            }

          val (basis', ast) = doBasdec ctx' (emptyBasis, basdec)
        in
          (mergeBases (basis, basis'), ast)
        end


      and doBasdec ctx (basis, basdec) =
        case basdec of

          DecPathMLB {path, token} =>
            doMLB ctx (basis, path, fileErrorHandler ctx path token)

        | DecPathSML {path, token} =>
            doSML ctx (basis, path, fileErrorHandler ctx path token)

        | DecMultiple {elems, ...} =>
            let
              fun doElem ((basis, ast), basdec) =
                let
                  val (basis', ast') = doBasdec ctx (basis, basdec)
                in
                  (basis', Ast.join (ast, ast'))
                end
            in
              Seq.iterate doElem (basis, Ast.empty) elems
            end

        | DecBasis {elems, ...} =>
            let
              fun doElem ((basis, ast), {basexp, ...}) =
                let
                  val (basis', ast') = doBasexp ctx (basis, basexp)
                in
                  (basis', Ast.join (ast, ast'))
                end
            in
              Seq.iterate doElem (basis, Ast.empty) elems
            end

        | DecLocalInEnd {basdec1, basdec2, ...} =>
            let
              (** TODO: FIX: this is not quite right; stuff exported by
                * basdec1 should not be visible in the overall basis.
                *)
              val (basis, ast1) = doBasdec ctx (basis, basdec1)
              val (basis, ast2) = doBasdec ctx (basis, basdec2)
            in
              (basis, Ast.join (ast1, ast2))
            end

        | DecAnn {basdec, ...} =>
            doBasdec ctx (basis, basdec)

        | _ =>
            (basis, Ast.empty)


      and doBasexp ctx (basis, basexp) =
        case basexp of
          BasEnd {basdec, ...} =>
            doBasdec ctx (basis, basdec)

        | LetInEnd {basdec, basexp, ...} =>
            let
              (** TODO: FIX: this is not quite right; stuff exported by
                * basdec should not be visible in the overall basis.
                *)
              val (basis, ast1) = doBasdec ctx (basis, basdec)
              val (basis, ast2) = doBasexp ctx (basis, basexp)
            in
              (basis, Ast.join (ast1, ast2))
            end

        | _ =>
            (basis, Ast.empty)


      fun topLevelError msg =
        raise Error.Error (Error.ErrorReport
          { header = "FILE ERROR"
          , content =
              [ ErrorReport.Paragraph
                  (msg ^ ": " ^ FilePath.toUnixPath mlbPath)
              ]
          })

      val (_, ast) =
        doMLB {parents = [], dir = FilePath.fromUnixPath "."}
          (emptyBasis, mlbPath, topLevelError)
    in
      ast
    end

end
