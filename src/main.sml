(** Copyright (c) 2020-2021 Sam Westrick
  *
  * See the file LICENSE for details.
  *)

val mlbPathVars = CommandLineArgs.parseStrings "mlb-path-var"
val skipBasis = not (CommandLineArgs.parseFlag "no-skip-basis")
val doPrettySML = CommandLineArgs.parseFlag "pretty"
val infile = List.hd (CommandLineArgs.positional ())

val pathmap = MLtonPathMap.getPathMap ()
val pathmap =
  List.concat (List.map MLtonPathMap.fromString mlbPathVars) @ pathmap

fun handleLexOrParseError exn =
  let
    val e =
      case exn of
        Error.Error e => e
      | other => raise other
    val hist = MLton.Exn.history exn
  in
    TerminalColorString.print
      (Error.show {highlighter = SOME SyntaxHighlighter.fuzzyHighlight} e);
    if List.null hist then () else
      print ("\n" ^ String.concat (List.map (fn ln => ln ^ "\n") hist));
    OS.Process.exit OS.Process.failure
  end


fun doMLB () =
  let
    val _ =
      ( print "==== PATH MAP ====\n"
      ; List.app
          (fn (key, value) => print (key ^ " " ^ value ^ "\n"))
          pathmap
      ; print "==================\n"
      )

    val ast =
      ParseAllSMLFromMLB.parse
        {skipBasis = skipBasis, pathmap = pathmap}
        (FilePath.fromUnixPath infile)
  in
    print "\nParsing succeeded.\n"
  end
  handle exn => handleLexOrParseError exn

(*
fun dumpTok tok =
  ( TerminalColorString.print (SyntaxHighlighter.highlight (Token.getSource tok))
  ; print "\n"
  )

fun dumpToks toks =
  Util.for (0, Seq.length toks) (fn i =>
    dumpTok (Seq.nth toks i))
*)

fun doSML () =
  let
    val source = Source.loadFromFile (FilePath.fromUnixPath infile)
    val ast = Parser.parse source

(*
    val _ = print ("============ tokens ===============\n")
    val toks = Lexer.tokens source
    val toks = Seq.filter (not o Token.isCommentOrWhitespace) toks
    val _ =
      Util.for (0, Seq.length toks) (fn i =>
        let
          val tok = Seq.nth toks i
        in
          dumpTok tok;
          dumpToks (Token.commentsAfter tok)
        end)

    val _ = print ("============ highlighted ===============\n")
*)

    val _ =
      TerminalColorString.print (SyntaxHighlighter.highlight source)

    val _ =
      if not doPrettySML then () else
      ( print "\n============== pretty ==============\n\n"
      ; print (PrettyPrintAst.pretty ast)
      ; print "\n\n====================================\n"
      )
  in
    print "\nParsing succeeded.\n"
  end
  handle exn => handleLexOrParseError exn


fun extError eo =
  ( case eo of
      SOME e => print ("Unsupported file extension: " ^ e ^ "\n")
    | NONE => print ("Missing file extension\n")
  ; OS.Process.exit OS.Process.failure
  )

val _ =
  case OS.Path.ext infile of
    SOME "mlb" => doMLB()
  | SOME e =>
      if List.exists (fn e' => e = e') ["sml","fun","sig"] then
        doSML ()
      else
        extError (SOME e)
  | _ => extError NONE
