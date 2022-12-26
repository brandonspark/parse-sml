(** Copyright (c) 2022 Sam Westrick
  *
  * See the file LICENSE for details.
  *)

structure TabbedTokenDoc :>
sig
  type doc
  type t = doc

  val empty: doc
  val space: doc
  val nospace: doc
  val token: Token.t -> doc
  val text: string -> doc
  val concat: doc * doc -> doc
  val letdoc: doc -> (DocVar.t -> doc) -> doc
  val var: DocVar.t -> doc

  datatype style =
    Inplace
  | Indented of {minIndent: int} option
  | RigidInplace
  | RigidIndented of {minIndent: int} option

  type tab
  val root: tab
  val newTabWithStyle: tab -> style * (tab -> doc) -> doc
  val newTab: tab -> (tab -> doc) -> doc
  val cond: tab -> {inactive: doc, active: doc} -> doc
  val at: tab -> doc -> doc

  val toStringDoc: {tabWidth: int, debug: bool} -> doc -> TabbedStringDoc.t
end =
struct

  structure D = TabbedStringDoc

  datatype style =
    Inplace
  | Indented of {minIndent: int} option
  | RigidInplace
  | RigidIndented of {minIndent: int} option

  (* Just need a unique name *)
  datatype tab =
    Tab of {id: int, style: style, parent: tab}
  | Root

  val tabCounter = ref 0

  fun mkTab parent style =
    let
      val c = !tabCounter
    in
      tabCounter := c+1;
      Tab {id = c, style = style, parent = parent}
    end


  val root = Root


  fun parent t =
    case t of
      Root => NONE
    | Tab {parent, ...} => SOME parent


  fun style t =
    case t of
      Root => Inplace
    | Tab {style=s, ...} => s


  fun tabToString t =
    case t of
      Tab {id=c, ...} => "[" ^ Int.toString c ^ "]"
    | Root => "[root]"


  structure TabKey =
  struct
    type t = tab
    fun compare (t1: tab, t2: tab) : order =
      case (t1, t2) of
        (Root, Root) => EQUAL
      | (Tab t1, Tab t2) => Int.compare (#id t1, #id t2)
      | (Tab _, Root) => GREATER
      | (Root, Tab _) => LESS
  end

  structure TabDict = Dict(TabKey)
  structure TabSet = Set(TabKey)
  structure VarDict = Dict(DocVar)

  datatype doc =
    Empty
  | Space
  | NoSpace
  | Concat of doc * doc
  | Token of Token.t
  | Text of string
  | At of tab * doc
  | NewTab of {tab: tab, doc: doc}
  | Cond of {tab: tab, inactive: doc, active: doc}
  | LetDoc of {var: DocVar.t, doc: doc, inn: doc}
  | Var of DocVar.t

  type t = doc

  val empty = Empty
  val nospace = NoSpace
  val space = Space
  val token = Token
  val text = Text
  val var = Var
  fun at t d = At (t, d)

  fun concat (d1, d2) =
    case (d1, d2) of
      (Empty, _) => d2
    | (_, Empty) => d1
    | _ => Concat (d1, d2)

  fun cond tab {inactive, active} = Cond {tab=tab, inactive=inactive, active=active}

  fun toString doc =
    case doc of
      Empty => ""
    | Space => "_"
    | NoSpace => "NoSpace"
    | Concat (d1, d2) => toString d1 ^ " ++ " ^ toString d2
    | Token t => "Token('" ^ Token.toString t ^ "')"
    | Text t => "Text('" ^ t ^ "')"
    | At (t, d) => "At(" ^ tabToString t ^ "," ^ toString d ^ ")"
    | NewTab {tab=t, doc=d, ...} => "NewTab(" ^ tabToString t ^ ", " ^ toString d ^ ")"
    | Cond {tab=t, inactive=df, active=dnf} =>
        "Cond(" ^ tabToString t ^ ", " ^ toString df ^ ", " ^ toString dnf ^ ")"
    | LetDoc {var, doc=d, inn} =>
        "LetDoc(" ^ DocVar.toString var ^ ", " ^ toString d ^ ", " ^ toString inn ^ ")"
    | Var v =>
        "Var(" ^ DocVar.toString v ^ ")"

  fun letdoc d f =
    let
      val v = DocVar.new ()
      val k = f v
    in
      LetDoc {var = v, doc = d, inn = k}
    end

  fun newTabWithStyle parent (style, genDocUsingTab: tab -> doc) =
    let
      val t = mkTab parent style
      val d = genDocUsingTab t
    in
      NewTab {tab=t, doc=d}
    end

  fun newTab parent f = newTabWithStyle parent (Inplace, f)

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)

  datatype anndoc =
    AnnEmpty
  | AnnNewline
  | AnnNoSpace
  | AnnSpace
  | AnnToken of {at: TabSet.t option, tok: Token.t}
  | AnnText of {at: TabSet.t option, txt: string}
  | AnnConcat of anndoc * anndoc
  | AnnAt of {mightBeFirst: bool, tab: tab, doc: anndoc}
  | AnnNewTab of {tab: tab, doc: anndoc}
  | AnnCond of {tab: tab, inactive: anndoc, active: anndoc}
  | AnnLetDoc of {var: DocVar.t, doc: anndoc, inn: anndoc}
  | AnnVar of DocVar.t


  fun annToString doc =
    case doc of
      AnnEmpty => ""
    | AnnNewline => "Newline"
    | AnnSpace => "_"
    | AnnNoSpace => "NoSpace"
    | AnnConcat (d1, d2) => annToString d1 ^ " ++ " ^ annToString d2
    | AnnToken {tok=t, ...} => "Token('" ^ Token.toString t ^ "')"
    | AnnText {txt=t, ...} => "Text('" ^ t ^ "')"
    | AnnAt {mightBeFirst, tab, doc} =>
        "At" ^ (if mightBeFirst then "!!" else "") ^ "(" ^ tabToString tab ^ ", " ^ annToString doc ^ ")"
    | AnnNewTab {tab=t, doc=d, ...} => "NewTab(" ^ tabToString t ^ ", " ^ annToString d ^ ")"
    | AnnCond {tab=t, inactive=df, active=dnf} =>
        "Cond(" ^ tabToString t ^ ", " ^ annToString df ^ ", " ^ annToString dnf ^ ")"
    | AnnLetDoc {var, doc=d, inn} =>
        "LetDoc(" ^ DocVar.toString var ^ ", " ^ annToString d ^ ", " ^ annToString inn ^ ")"
    | AnnVar v =>
        "Var(" ^ DocVar.toString v ^ ")"


  fun annotate doc =
    let
      (* if tab in broken, then tab has definitely had at least one break *)
      fun loop vars (doc, broken) =
        case doc of
          Empty => (AnnEmpty, broken)
        | Space => (AnnSpace, broken)
        | NoSpace => (AnnNoSpace, broken)
        | Token t => (AnnToken {at=NONE, tok=t}, broken)
        | Text t => (AnnText {at=NONE, txt=t}, broken)
        | Var v =>
            let
              val (_, vbroken) = VarDict.lookup vars v
            in
              (AnnVar v, TabSet.union (vbroken, broken))
            end
        | LetDoc {var, doc, inn} =>
            let
              val (doc, vbroken) = loop vars (doc, TabSet.empty)
              val vars = VarDict.insert vars (var, (doc, vbroken))
              val (inn, broken) = loop vars (inn, broken)
            in
              (AnnLetDoc {var=var, doc=doc, inn=inn}, broken)
            end
        | At (tab, doc) =>
            let
              val (mightBeFirst, broken) =
                if TabSet.contains broken tab then
                  (false, broken)
                else
                  (true, TabSet.insert broken tab)

              val (doc, broken) = loop vars (doc, broken)
            in
              ( AnnAt
                  { mightBeFirst = mightBeFirst
                  , tab = tab
                  , doc = doc
                  }
              , broken
              )
            end
        | Concat (d1, d2) =>
            let
              val (d1, broken) = loop vars (d1, broken)
              val (d2, broken) = loop vars (d2, broken)
            in
              (AnnConcat (d1, d2), broken)
            end
        | NewTab {tab, doc} =>
            let
              val (doc, broken) = loop vars (doc, broken)
            in
              ( AnnNewTab {tab = tab, doc = doc}
              , broken
              )
            end
        | Cond {tab, inactive, active} =>
            let
              val (inactive, broken1) = loop vars (inactive, broken)
              val (active, broken2) = loop vars (active, broken)
            in
              ( AnnCond {tab=tab, inactive=inactive, active=active}
              , TabSet.intersect (broken1, broken2)
              )
            end

      val (anndoc, _) = loop VarDict.empty (doc, TabSet.empty)
    in
      anndoc
    end

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)

  fun ensureSpaces debug (doc: anndoc) =
    let
      fun dbgprintln s =
        if not debug then ()
        else print (s ^ "\n")

      datatype edge = Spacey | MaybeNotSpacey
      datatype tab_constraint = Active | Inactive
      type context = tab_constraint TabDict.t

      fun edgeOptToString e =
        case e of
          NONE => "NONE"
        | SOME Spacey => "Spacey"
        | SOME MaybeNotSpacey => "MaybeNotSpacey"

      fun markInactive ctx tab =
        TabDict.insert ctx (tab, Inactive)

      fun markActive ctx tab =
        case tab of
          Root => ctx
        | Tab {parent, ...} =>
            markActive (TabDict.insert ctx (tab, Active)) parent

      fun edge {left: bool} ctx doc =
        let
          fun loop ctx vars doc =
            case doc of
              AnnEmpty => NONE
            | AnnNewline => SOME Spacey
            | AnnSpace => SOME Spacey
            | AnnNoSpace => SOME Spacey (* pretends to be a space, but then actually is elided *)
            | AnnToken _ => SOME MaybeNotSpacey
            | AnnText _ => SOME MaybeNotSpacey
            | AnnVar v => VarDict.lookup vars v
            | AnnLetDoc {var, doc, inn} =>
                let
                  val e = loop ctx vars doc
                  val vars = VarDict.insert vars (var, e)
                in
                  loop ctx vars inn
                end
            | AnnAt {mightBeFirst, tab, doc} =>
                let
                  val leftEdge =
                    case TabDict.find ctx tab of
                      SOME Active =>
                        if mightBeFirst then
                          NONE
                        else
                          SOME Spacey
                    | _ => NONE
                in
                  if left then
                    leftEdge
                  else
                    case loop ctx vars doc of
                      SOME ee => SOME ee
                    | _ => leftEdge
                end

            | AnnConcat (d1, d2) =>
                if left then
                  (case loop ctx vars d1 of
                    SOME xs => SOME xs
                  | NONE => loop ctx vars d2)
                else
                  (case loop ctx vars d2 of
                    SOME xs => SOME xs
                  | NONE => loop ctx vars d1)
            | AnnNewTab {doc=d, ...} => loop ctx vars d
            | AnnCond {tab, inactive, active} =>
                let
                  val result =
                    case TabDict.find ctx tab of
                      SOME Active =>
                        let
                          val result = loop ctx vars active
                        in
                          dbgprintln (annToString doc ^ ": ACTIVE: " ^ edgeOptToString result);
                          result
                        end
                    | SOME Inactive =>
                        let
                          val result = loop ctx vars inactive
                        in
                          dbgprintln (annToString doc ^ ": INACTIVE: " ^ edgeOptToString result);
                          result
                        end
                    | NONE =>
                        let
                          val r1 = loop (markInactive ctx tab) vars inactive
                          val r2 = loop (markActive ctx tab) vars active
                          val result =
                            case (r1, r2) of
                              (SOME MaybeNotSpacey, _) => SOME MaybeNotSpacey
                            | (_, SOME MaybeNotSpacey) => SOME MaybeNotSpacey
                            | (SOME Spacey, SOME Spacey) => SOME Spacey
                            | (NONE, _) => NONE
                            | (_, NONE) => NONE
                        in
                          dbgprintln (annToString doc ^ ": UNSURE: ACTIVE? " ^ edgeOptToString r2 ^ "; INACTIVE? " ^ edgeOptToString r1 ^ "; OVERALL: " ^ edgeOptToString result);
                          result
                        end
                in
                  result
                end
        in
          loop ctx VarDict.empty doc
        end

      fun leftEdge ctx doc = edge {left=true} ctx doc
      fun rightEdge ctx doc = edge {left=false} ctx doc

      fun checkInsertSpace (needSpaceBefore, needSpaceAfter) doc =
        let
          val origDoc = doc

          val doc =
            if not needSpaceBefore then doc
            else
              ( dbgprintln ("need space before " ^ annToString origDoc)
              ; AnnConcat (AnnSpace, doc)
              )

          val doc =
            if not needSpaceAfter then doc
            else
              ( dbgprintln ("need space after " ^ annToString origDoc)
              ; AnnConcat (doc, AnnSpace)
              )
        in
          doc
        end

      fun loop ctx (needSpace as (needSpaceBefore, needSpaceAfter)) (doc, vars) : anndoc * (bool * bool) VarDict.t =
        case doc of
          AnnSpace => (doc, vars)
        | AnnNoSpace => (doc, vars)
        | AnnNewline => (doc, vars)
        | AnnToken t => (checkInsertSpace needSpace doc, vars)
        | AnnText t => (checkInsertSpace needSpace doc, vars)
        | AnnEmpty =>
            if needSpaceBefore orelse needSpaceAfter then
              (AnnSpace, vars)
            else
              (AnnEmpty, vars)
        | AnnAt {mightBeFirst, tab, doc} =>
            let
              val needSpaceBefore' =
                case TabDict.find ctx tab of
                  SOME Active =>
                    if mightBeFirst then
                      needSpaceBefore
                    else
                      false
                | _ => needSpaceBefore

              val (doc, vars) = loop ctx (false, needSpaceAfter) (doc, vars)

              val result =
                AnnAt
                  { mightBeFirst = mightBeFirst
                  , tab = tab
                  , doc = doc
                  }
            in
              ( if needSpaceBefore' then
                  AnnConcat (AnnSpace, result)
                else
                  result
              , vars
              )
            end
        | AnnNewTab {tab, doc} =>
            let
              val (doc, vars) = loop ctx needSpace (doc, vars)
            in
              ( AnnNewTab {tab = tab, doc = doc}
              , vars
              )
            end
        | AnnCond {tab, inactive, active} =>
            let
              val (inactive, vars) = loop (markInactive ctx tab) needSpace (inactive, vars)
              val (active, vars) = loop (markActive ctx tab) needSpace (active, vars)
            in
              ( AnnCond {tab = tab, inactive = inactive, active = active}
              , vars
              )
            end
        | AnnConcat (d1, d2) =>
            let
              val (d1, vars) = loop ctx (needSpaceBefore, false) (d1, vars)

              val needSpaceBefore2 =
                case rightEdge ctx d1 of
                  SOME MaybeNotSpacey => true
                | _ => false

              val (d2, vars) = loop ctx (needSpaceBefore2, needSpaceAfter) (d2, vars)
            in
              (AnnConcat (d1, d2), vars)
            end
        | AnnLetDoc {var, doc, inn} =>
            let
              val vars = VarDict.insert vars (var, (false, false))
              val (inn, vars) = loop ctx needSpace (inn, vars)
            in
              (AnnLetDoc {var=var, doc=doc, inn=inn}, vars)
            end
        | AnnVar v =>
            let
              val (needSpaceBefore', needSpaceAfter') = VarDict.lookup vars v
              val newVal =
                ( needSpaceBefore orelse needSpaceBefore'
                , needSpaceAfter orelse needSpaceAfter'
                )
              val vars = VarDict.insert vars (v, newVal)
            in
              (AnnVar v, vars)
            end

      val (result, varinfo) = loop TabDict.empty (false, false) (doc, VarDict.empty)

      fun updateVars doc =
        case doc of
          AnnLetDoc {var, doc=d, inn} =>
            let
              val needSpace = VarDict.lookup varinfo var
              val (d, _) = loop TabDict.empty needSpace (d, varinfo)
            in
              AnnLetDoc {var=var, doc=d, inn = updateVars inn}
            end
        | AnnConcat (d1, d2) =>
            AnnConcat (updateVars d1, updateVars d2)
        | AnnAt {mightBeFirst, tab, doc} =>
            AnnAt {mightBeFirst=mightBeFirst, tab=tab, doc = updateVars doc}
        | AnnCond {tab, inactive, active} =>
            AnnCond {tab=tab, inactive = updateVars inactive, active = updateVars active}
        | AnnNewTab {tab, doc} =>
            AnnNewTab {tab=tab, doc = updateVars doc}
        | _ => doc

      (* val _ = dbgprintln ("ensureSpaces OUTPUT: " ^ toString result) *)
    in
      updateVars result
    end

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)

  structure TokenKey =
  struct
    type t = Token.t
    fun compare (t1, t2) =
      let
        val s1 = Token.getSource t1
        val s2 = Token.getSource t2
      in
        case Int.compare (Source.absoluteStartOffset s1, Source.absoluteStartOffset s2) of
          EQUAL => Int.compare (Source.absoluteEndOffset s1, Source.absoluteEndOffset s2)
        | other => other
      end
  end

  structure TokenDict = Dict(TokenKey)
  structure TokenSet = Set(TokenKey)

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)

  fun flowAts debug (doc: anndoc) =
    let
      fun dbgprintln s =
        if not debug then ()
        else print (s ^ "\n")

      datatype tab_constraint = Active | Inactive
      type context = tab_constraint TabDict.t

      fun markInactive ctx tab =
        TabDict.insert ctx (tab, Inactive)

      fun markActive ctx tab =
        case tab of
          Root => ctx
        | Tab {parent, ...} =>
            markActive (TabDict.insert ctx (tab, Active)) parent

      fun flowunion (flow1, flow2) =
        case (flow1, flow2) of
          (SOME ts1, SOME ts2) => SOME (TabSet.union (ts1, ts2))
        | (NONE, _) => flow2
        | (_, NONE) => flow1

      fun loop ctx (flowval, vars, doc) =
        case doc of
          AnnEmpty => (flowval, vars, doc)
        | AnnNewline => (flowval, vars, doc)
        | AnnSpace => (flowval, vars, doc)
        | AnnNoSpace => (flowval, vars, doc)
        | AnnToken {tok, ...} =>
            let
              val _ =
                Option.app (fn ts =>
                  dbgprintln
                    ("token '" ^ Token.toString tok ^ "' at: " ^
                     String.concatWith " " (List.map tabToString (TabSet.listKeys ts))))
                flowval
            in
              (NONE, vars, AnnToken {tok=tok, at=flowval})
            end
        | AnnText {txt, ...} =>
            let
              val _ =
                Option.app (fn ts =>
                  dbgprintln
                    ("text '" ^ txt ^ "' at: " ^
                     String.concatWith " " (List.map tabToString (TabSet.listKeys ts))))
                flowval
            in
              (NONE, vars, AnnText {txt=txt, at=flowval})
            end
        | AnnAt {mightBeFirst, tab, doc} =>
            let
              (* val flowval = SOME (TabSet.singleton tab) *)
              val flowval = flowunion (flowval, SOME (TabSet.singleton tab))
              val (_, vars, doc) = loop ctx (flowval, vars, doc)
            in
              (NONE, vars, AnnAt {mightBeFirst=mightBeFirst, tab=tab, doc=doc})
            end
        | AnnConcat (d1, d2) =>
            let
              val (flowval, vars, d1) = loop ctx (flowval, vars, d1)
              val (flowval, vars, d2) = loop ctx (flowval, vars, d2)
            in
              (flowval, vars, AnnConcat (d1, d2))
            end
        | AnnNewTab {tab, doc} =>
            let
              val (flowval, vars, doc) = loop ctx (flowval, vars, doc)
            in
              (flowval, vars, AnnNewTab {tab=tab, doc=doc})
            end
        | AnnCond {tab, active, inactive} =>
            (case TabDict.find ctx tab of
              SOME Active => loop ctx (flowval, vars, active)
            | SOME Inactive => loop ctx (flowval, vars, inactive)
            | _ =>
                let
                  val (flow1, vars, inactive) = loop (markInactive ctx tab) (flowval, vars, inactive)
                  val (flow2, vars, active) = loop (markActive ctx tab) (flowval, vars, active)
                  val flowval =
                    (* TODO: is union necessary here? *)
                    flowunion (flow1, flow2)
                in
                  (flowval, vars, AnnCond {tab=tab, active=active, inactive=inactive})
                end)
        | AnnLetDoc {var, doc, inn} =>
            let
              val vars = VarDict.insert vars (var, NONE)
              val (flowval, vars, inn) = loop ctx (flowval, vars, inn)
            in
              (flowval, vars, AnnLetDoc {var=var, doc=doc, inn=inn})
            end
        | AnnVar v =>
            let
              val vars =
                VarDict.insert vars (v, flowunion (VarDict.lookup vars v, flowval))
            in
              (NONE, vars, AnnVar v)
            end

      val (_, varinfo, doc) =
        loop TabDict.empty (SOME (TabSet.singleton Root), VarDict.empty, doc)

      fun updateVars doc =
        case doc of
          AnnLetDoc {var, doc=d, inn} =>
            let
              val flowval = VarDict.lookup varinfo var
              val (_, _, d) = loop TabDict.empty (flowval, varinfo, d)
            in
              AnnLetDoc {var=var, doc=d, inn = updateVars inn}
            end
        | AnnConcat (d1, d2) =>
            AnnConcat (updateVars d1, updateVars d2)
        | AnnAt {mightBeFirst, tab, doc} =>
            AnnAt {mightBeFirst=mightBeFirst, tab=tab, doc = updateVars doc}
        | AnnCond {tab, inactive, active} =>
            AnnCond {tab=tab, inactive = updateVars inactive, active = updateVars active}
        | AnnNewTab {tab, doc} =>
            AnnNewTab {tab=tab, doc = updateVars doc}
        | _ => doc
    in
      updateVars doc
    end

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)

  fun insertComments debug (doc: anndoc) =
    let
      fun dbgprintln s =
        if not debug then ()
        else print (s ^ "\n")

      fun isLast tok =
        not (Option.isSome (Token.nextTokenNotCommentOrWhitespace tok))

      fun commentsToDocs cs =
        Seq.map (fn c => AnnToken {at=NONE, tok=c}) cs

      fun loop doc =
        case doc of
          AnnEmpty => doc
        | AnnNewline => doc
        | AnnNoSpace => doc
        | AnnSpace => doc
        | AnnText _ => doc
        | AnnAt {mightBeFirst, tab, doc} =>
            AnnAt {mightBeFirst=mightBeFirst, tab=tab, doc = loop doc}
        | AnnConcat (d1, d2) =>
            AnnConcat (loop d1, loop d2)
        | AnnNewTab {tab, doc} =>
            AnnNewTab {tab = tab, doc = loop doc}
        | AnnCond {tab, inactive, active} =>
            AnnCond {tab = tab, inactive = loop inactive, active = loop active}

        | AnnToken {at = NONE, tok} =>
            let
              val commentsBefore =
                commentsToDocs (Token.commentsBefore tok)
              val commentsAfter =
                if not (isLast tok) then Seq.empty () else
                commentsToDocs (Token.commentsAfter tok)
              val all =
                Seq.append3 (commentsBefore, Seq.singleton doc, commentsAfter)
            in
              Seq.iterate AnnConcat AnnEmpty all
            end

        | AnnToken {at = flow as SOME tabs, tok} =>
            let
              val tab =
                (* TODO: what to do when there are multiple possible tabs
                 * this token could be at? Here we just pick the first
                 * of these in the set, and usually it seems each token
                 * is only ever 'at' one possible tab...
                 *)
                List.hd (TabSet.listKeys tabs)

              val commentsBefore =
                commentsToDocs (Token.commentsBefore tok)

              val commentsAfter =
                if not (isLast tok) then Seq.empty () else
                commentsToDocs (Token.commentsAfter tok)

              fun withBreak d =
                AnnAt {mightBeFirst=false, tab=tab, doc=d}

              val all =
                Seq.append3 (commentsBefore, Seq.singleton doc, commentsAfter)
            in
              Seq.iterate AnnConcat
                (Seq.nth all 0)
                (Seq.map withBreak (Seq.drop all 1))
            end

    in
      flowAts debug (loop doc)
    end

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)

  (* TODO: bug: this doesn't insert a blank line where it should in this case:
   *
   *   <token1>
   *   ++
   *   newTab root (fn inner =>
   *     at(root) ++
   *     at(inner) ++ <token2>
   *   )
   *
   * The flow analysis will observe that <token2> is at 'inner'. But it's
   * possible that 'inner' is inactive and 'root' is active. Visually, this
   * will look like <token2> is below <token1>, and therefore blank lines
   * should be inserted between if necessary.
   *
   * However, our technique for inserting blank lines (currently) is to
   * insert a conditional newline which is active only if the flowval tab
   * is active.
   *
   * In this particular example, the fix would be to conditionally newline
   * if either 'root' is active OR 'inner' is active. But how to compute
   * that?
   *)
  fun insertBlankLines debug (doc: anndoc) =
    let
      fun dbgprintln s =
        if not debug then ()
        else print (s ^ "\n")

      fun breaksBefore doc tab n =
        if n = 0 then doc else
        let
          val doc =
            AnnConcat
              ( AnnCond {tab = tab, inactive = AnnEmpty, active = AnnNewline}
              , doc
              )
        in
          breaksBefore doc tab (n-1)
        end

      fun prevTokenNotWhitespace t =
        case Token.prevToken t of
          NONE => NONE
        | SOME p =>
            if Token.isWhitespace p then
              prevTokenNotWhitespace p
            else
              SOME p

      fun loop doc =
        case doc of
          AnnEmpty => doc
        | AnnNewline => doc
        | AnnNoSpace => doc
        | AnnSpace => doc
        | AnnText _ => doc
        | AnnAt {mightBeFirst, tab, doc} =>
            AnnAt {mightBeFirst=mightBeFirst, tab=tab, doc = loop doc}
        | AnnToken {at = NONE, tok} => doc
        | AnnToken {at = SOME tabs, tok} =>
            (case prevTokenNotWhitespace tok of
              NONE => doc
            | SOME prevTok =>
                let
                  val diff = Token.lineDifference (prevTok, tok) - 1
                  val diff = Int.max (0, Int.min (2, diff))
                  val _ = dbgprintln ("line diff ('" ^ Token.toString prevTok ^ "','" ^ Token.toString tok ^ "'): " ^ Int.toString diff)
                in
                  if diff = 0 then
                    doc
                  else
                    (* TODO: what to do when there are multiple possible tabs
                     * this token could be at? Here we just pick the first
                     * of these in the set, and usually it seems each token
                     * is only ever 'at' one possible tab...
                     *)
                    breaksBefore doc (List.hd (TabSet.listKeys tabs)) diff
                end)
        | AnnConcat (d1, d2) =>
            AnnConcat (loop d1, loop d2)
        | AnnNewTab {tab, doc} =>
            AnnNewTab {tab = tab, doc = loop doc}
        | AnnCond {tab, inactive, active} =>
            AnnCond {tab = tab, inactive = loop inactive, active = loop active}
    in
      loop doc
    end

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)

  structure TCS = TerminalColorString

  fun tokenToStringDoc currentTab tabWidth tok =
    let
      val src = Token.getSource tok

      (** effective offset of the beginning of this token within its line,
        * counting tab-widths appropriately.
        *)
      val effectiveOffset =
        let
          val {col, line=lineNum} = Source.absoluteStart src
          val len = col-1
          val charsBeforeOnSameLine =
            Source.take (Source.wholeLine src lineNum) len
          fun loop effOff i =
            if i >= len then effOff
            else if #"\t" = Source.nth charsBeforeOnSameLine i then
              (* advance up to next tabstop *)
              loop (effOff + tabWidth - effOff mod tabWidth) (i+1)
            else
              loop (effOff+1) (i+1)
        in
          loop 0 0
        end

      fun strip line =
        let
          val (_, ln) =
            TCS.stripEffectiveWhitespace
              {tabWidth=tabWidth, removeAtMost=effectiveOffset}
              line
        in
          ln
        end

      val t = SyntaxHighlighter.highlightToken tok

      val pieces =
        Seq.map
          (fn (i, j) => D.text (strip (TCS.substring (t, i, j-i))))
          (Source.lineRanges src)
    in
      if Seq.length pieces = 1 then
        (false, D.text t)
      else
        ( true
        , D.newTab currentTab (D.RigidInplace, fn tab =>
            Seq.iterate
              D.concat
              D.empty
              (Seq.map (fn x => D.at tab x) pieces))
        )
    end


  (* ====================================================================== *)


  fun toStringDoc (args as {tabWidth, debug}) doc =
    let
      fun dbgprintln s =
        if not debug then ()
        else print (s ^ "\n")

      val doc = annotate doc
      val doc = flowAts debug doc
      val doc = insertComments debug doc
      (* val _ = dbgprintln ("TabbedTokenDoc.toStringDoc before ensureSpaces: " ^ annToString doc) *)
      val doc = ensureSpaces debug doc
      (* val _ = dbgprintln ("TabbedTokenDoc.toStringDoc before insertBlankLines: " ^ annToString doc) *)
      val doc = insertBlankLines debug doc
      (* val _ = dbgprintln ("TabbedTokenDoc.toStringDoc after insertBlankLines: " ^ annToString doc) *)
      (* val doc = removeAnnotations doc *)

      fun loop currentTab tabmap doc =
        case doc of
          AnnEmpty => D.empty
        | AnnNoSpace => D.empty
        | AnnNewline => D.newline
        | AnnSpace => D.space
        | AnnConcat (d1, d2) =>
            D.concat (loop currentTab tabmap d1, loop currentTab tabmap d2)
        | AnnText {txt, ...} => D.text (TerminalColorString.fromString txt)
        | AnnToken {at, tok} =>
            let
              val tab =
                case at of
                  NONE => currentTab
                | SOME tabs =>
                    (* TODO: what to do when there are multiple possible
                     * tabs here? *)
                    TabDict.lookup tabmap (List.hd (TabSet.listKeys tabs))

              val (shouldBeRigid, doc) = tokenToStringDoc tab tabWidth tok
            in
              doc
            end
        | AnnAt {tab, doc, ...} =>
            D.at (TabDict.lookup tabmap tab) (loop currentTab tabmap doc)
        | AnnCond {tab, inactive, active} =>
            D.cond (TabDict.lookup tabmap tab)
              { inactive = loop currentTab tabmap inactive
              , active = loop currentTab tabmap active
              }
        | AnnNewTab {tab, doc} =>
            let
              val s =
                case style tab of
                  Inplace => D.Inplace
                | Indented xx => D.Indented xx
                | RigidInplace => D.RigidInplace
                | RigidIndented xx => D.RigidIndented xx
            in
              D.newTab
                (TabDict.lookup tabmap (valOf (parent tab)))
                (s, fn tab' =>
                  loop tab' (TabDict.insert tabmap (tab, tab')) doc)
            end
    in
      loop D.root (TabDict.singleton (Root, D.root)) doc
    end

end