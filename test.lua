-- don't use require; that will pick up luarocks-installed module, not checkout
local fennel = dofile("fennel.lua")
table.insert(package.loaders or package.searchers, fennel.searcher)
local generate = fennel.dofile("generate.fnl")
local view = fennel.dofile("fennelview.fnl")

-- Allow deterministic re-runs of generated things.
local seed = os.getenv("SEED") or os.time()
print("SEED=" .. seed)
math.randomseed(seed)

local pass, fail, err = 0, 0, 0

-- one global to store values in during tests
_G.tbl = {}

---- core language tests ----

local cases = {
    calculations = {
        ["(+ 1 2 (- 1 2))"]=2,
        ["(* 1 2 (/ 1 2))"]=1,
        ["(+ 1 2 (^ 1 2))"]=4,
        ["(% 1 2 (- 1 2))"]=0,
        -- 1 arity results
        ["(- 1)"]=-1,
        ["(/ 2)"]=1/2,
        -- ["(// 2)"]=1//2,
        -- 0 arity results
        ["(+)"]=0,
        ["(*)"]=1,
    },

    booleans = {
        ["(or false nil true 12 false)"]=true,
        ["(or 11 true false)"]=11,
        ["(and true 12 \"hey\")"]="hey",
        ["(and 43 table false)"]=false,
        ["(not true)"]=false,
        ["(not 39)"]=false,
        ["(not nil)"]=true,
        -- 1 arity results
        ["(or 5)"]=5,
        ["(and 5)"]=5,
        -- 0 arity results
        ["(or)"]=false,
        ["(and)"]=true,
    },

    comparisons = {
        ["(> 2 0)"]=true,
        ["(> 2 0 -1)"]=true,
        ["(<= 5 1 91)"]=false,
        ["(> -4 89)"]=false,
        ["(< -4 89)"]=true,
        ["(>= 22 (+ 21 1))"]=true,
        ["(<= 88 32)"]=false,
        ["(~= 33 1)"]=true,
        ["(not= 33 1)"]=true,
        ["(= 1 1 2 2)"]=false,
        ["(~= 6 6 9)"]=true,
        ["(let [f (fn [] (tset tbl :dbl (+ 1 (or (. tbl :dbl) 0))) 1)]\
            (< 0 (f) 2) (. tbl :dbl))"]=1,
    },

    parsing = {
        ["\"\\\\\""]="\\",
        ["\"abc\\\"def\""]="abc\"def",
        ["\'abc\\\"\'"]="abc\"",
        ["\"abc\\240\""]="abc\240",
        ["\"abc\n\\240\""]="abc\n\240",
        ["150_000"]=150000,
    },

    functions = {
        -- regular function
        ["((fn [x] (* x 2)) 26)"]=52,
        -- nested functions
        ["(let [f (fn [x y f2] (+ x (f2 y)))\
                  f2 (fn [x y] (* x (+ 2 y)))\
                  f3 (fn [f] (fn [x] (f 5 x)))]\
                  (f 9 5 (f3 f2)))"]=44,
        -- closures can set vars they close over
        ["(var a 11) (let [f (fn [] (set a (+ a 2)))] (f) (f) a)"]=15,
        -- partial application
        ["(let [add (fn [x y] (+ x y)) inc (partial add 1)] (inc 99))"]=100,
        ["(let [add (fn [x y z] (+ x y z)) f2 (partial add 1 2)] (f2 6))"]=9,
        ["(let [add (fn [x y] (+ x y)) add2 (partial add)] (add2 99 2))"]=101,
        -- functions with empty bodies return nil
        ["(if (= nil ((fn [a]) 1)) :pass :fail)"]="pass",
        -- basic lambda
        ["((lambda [x] (+ x 2)) 4)"]=6,
        -- vararg lambda
        ["((lambda [x ...] (+ x 2)) 4)"]=6,
        -- lambdas perform arity checks
        ["(let [(ok e) (pcall (lambda [x] (+ x 2)))]\
            (string.match e \"Missing argument x\"))"]="Missing argument x",
        -- lambda arity checks skip argument names starting with ?
        ["(let [(ok val) (pcall (λ [?x] (+ (or ?x 1) 8)))] (and ok val))"]=9,
        -- method calls work
        ["(: :hello :find :e)"]=2,
        -- method calls don't double side effects
        ["(var a 0) (let [f (fn [] (set a (+ a 1)) :hi)] (: (f) :find :h)) a"]=1,
    },

    conditionals = {
        -- basic if
        ["(let [x 1 y 2] (if (= (* 2 x) y) \"yep\"))"]="yep",
        -- if can contain side-effects
        ["(var x 12) (if true (set x 22) 0) x"]=22,
        -- else branch works
        ["(if false \"yep\" \"nope\")"]="nope",
        -- else branch runs on nil
        ["(if non-existent 1 (* 3 9))"]=27,
        -- else works with temporaries
        ["(let [x {:y 2}] (if false \"yep\" (< 1 x.y 3) \"uh-huh\" \"nope\"))"]="uh-huh",
        -- when is for side-effects
        ["(var [a z] [0 0]) (when true (set a 192) (set z 12)) (+ z a)"]=204,
        -- when treats nil as falsey
        ["(var a 884) (when nil (set a 192)) a"]=884,
        -- when body does not run on false
        ["(when (= 12 88) (os.exit 1)) false"]=false,
    },

    core = {
        -- comments
        ["74 ; (require \"hey.dude\")"]=74,
        -- comments go to the end of the line
        ["(var x 12) ;; (set x 99)\n x"]=12,
        -- calling built-in lua functions
        ["(table.concat [\"ab\" \"cde\"] \",\")"]="ab,cde",
        -- table lookup
        ["(let [t []] (table.insert t \"lo\") (. t 1))"]="lo",
        -- nested table lookup
        ["(let [t [[21]]] (+ (. (. t 1) 1) (. t 1 1)))"]=42,
        -- table lookup base case
        ["(let [x 17] (. 17))"]=17,
        -- table lookup with literal
        ["(+ (. {:a 93 :b 4} :a) (. [1 2 3] 2))"]=95,
        -- set works with multisyms
        ["(let [t {}] (set t.a :multi) (. t :a))"]="multi",
        -- set works on parent scopes
        ["(var n 0) (let [f (fn [] (set n 96))] (f) n)"]=96,
        -- set-forcibly! works on local & let vars
        ["(local a 3) (let [b 2] (set-forcibly! a 7) (set-forcibly! b 6) (+ a b))"]=13,
        -- local names with dashes in them
        ["(let [my-tbl {} k :key] (tset my-tbl k :val) my-tbl.key)"]="val",
        -- functions inside each
        ["(var i 0) (each [_ ((fn [] (pairs [1])))] (set i 1)) i"]=1,
        -- let with nil value
        ["(let [x 3 y nil z 293] z)"]=293,
        -- nested let inside loop
        ["(var a 0) (for [_ 1 3] (let [] (table.concat []) (set a 33))) a"]=33,
        -- set can be used as expression
        ["(var x 1) (let [_ (set x 92)] x)"]=92,
        -- tset can be used as expression
        ["(let [t {} _ (tset t :a 84)] (. t :a))"]=84,
        -- Setting multivalue vars
        ["(do (var a nil) (var b nil) (local ret (fn [] a)) (set (a b) (values 4 5)) (ret))"]=4,
        -- Tset doesn't screw up with table literal
        ["(do (tset {} :a 1) 1)"]=1,
    },

    ifforms = {
        ["(do (fn myfn [x y z] (+ x y z)) (myfn 1 (if 1 2 3) 4))"]=7,
        ["(do (fn myfn [x y z] (+ x y z)) (myfn 1 (if 1 (values 2 5) 3) 4))"]=7,
        ["(let [x (if false 3 (values 2 5))] x)"]=2,
        ["(if (values 1 2) 3 4)"]=3,
        ["(if (values 1) 3 4)"]=3,
        ["(do (fn myfn [x y z] (+ x y z)) (myfn 1 4 (if 1 2 3)))"]=7,
    },

    destructuring = {
        -- regular tables
        ["(let [[a b c d] [4 2 43 7]] (+ (* a b) (- c d)))"]=44,
        -- mismatched count
        ["(let [[a b c] [4 2]] (or c :missing))"]="missing",
        ["(let [[a b] [9 2 49]] (+ a b))"]=11,
        -- recursively
        ["(let [[a [b c] d] [4 [2 43] 7]] (+ (* a b) (- c d)))"]=44,
        -- multiple values
        ["(let [(a b) ((fn [] (values 4 2)))] (+ a b))"]=6,
        -- multiple values recursively
        ["(let [(a [b [c] d]) ((fn [] (values 4 [2 [1] 9])))] (+ a b c d))"]=16,
        -- multiple values without function wrapper
        ["(let [(a [b [c] d]) (values 4 [2 [1] 9])] (+ a b c d))"]=16,
        -- global destructures tables
        ["(global [a b c d] [4 2 43 7]) (+ (* a b) (- c d))"]=44,
        -- global works with multiple values
        ["(global (a b) ((fn [] (values 4 29)))) (+ a b)"]=33,
        -- local keyword
        ["(local (-a -b) ((fn [] (values 4 29)))) (+ -a -b)"]=33,
        -- rest args
        ["(let [[a b & c] [1 2 3 4 5]] (+ a (. c 2) (. c 3)))"]=10,
        -- all vars get flagged as var
        ["(var [a [b c]] [1 [2 3]]) (set a 2) (set c 8) (+ a b c)"]=12,
        -- fn args
        ["((fn dest [a [b c] [d]] (+ a b c d)) 5 [9 7] [2])"]=23,
        -- each
        ["(var x 0) (each [_ [a b] (ipairs [[1 2] [3 4]])] (set x (+ x (* a b)))) x"]=14,
        -- key/value destructuring
        ["(let [{:a x :b y} {:a 2 :b 4}] (+ x y))"]=6,
        -- nesting k/v and sequential
        ["(let [{:a [x y z]} {:a [1 2 4]}] (+ x y z))"]=7,
    },

    loops = {
        -- numeric loop
        ["(var x 0) (for [y 1 5] (set x (+ x 1))) x"]=5,
        -- numeric loop with step
        ["(var x 0) (for [y 1 20 2] (set x (+ x 1))) x"]=10,
        -- while loop
        ["(var x 0) (while (< x 7) (set x (+ x 1))) x"]=7,
        -- each loop iterates over tables
        ["(let [t {:a 1 :b 2} t2 {}]\
               (each [k v (pairs t)]\
               (tset t2 k v))\
            (+ t2.a t2.b))"]=3,
    },

    edge = {
        -- IIFE in if statement required
        ["(let [(a b c d e f g) (if (= (+ 1 1) 2) (values 1 2 3 4 5 6 7))] (+ a b c d e f g))"]=28,
        -- IIFE in if statement required v2
        ["(let [(a b c d e f g) (if (= (+ 1 1) 3) nil\
                                       ((or unpack table.unpack) [1 2 3 4 5 6 7]))]\
            (+ a b c d e f g))"]=28,
        -- IIFE if test v3
        ["(# [(if (= (+ 1 1) 2) (values 1 2 3 4 5) (values 1 2 3))])"]=5,
        -- IIFE if test v4
        ["(select \"#\" (if (= 1 (- 3 2)) (values 1 2 3 4 5) :onevalue))"]=5,
        -- Values special in array literal
        ["(# [(values 1 2 3 4 5)])"]=5,
        ["(let [x (if 3 4 5)] x)"]=4,
        ["(do (local c1 20) (local c2 40) (fn xyz [A B] (and A B)) (xyz (if (and c1 c2) true false) 52))"]=52
    },

    macros = {
        -- built-in macros
        ["(let [x [1]]\
            (doto x (table.insert 2) (table.insert 3)) (table.concat x))"]="123",
        -- arrow threading
        ["(-> (+ 85 21) (+ 1) (- 99))"]=8,
        ["(->> (+ 85 21) (+ 1) (- 99))"]=-8,
        -- nil-safe forms
        ["(-?> {:a {:b {:c :z}}} (. :a) (. :b) (. :c))"]="z",
        ["(-?> {:a {:b {:c :z}}} (. :a) (. :missing) (. :c))"]=nil,
        ["(-?>> :w (. {:w :x}) (. {:x :y}) (. {:y :z}))"]="z",
        ["(-?>> :w (. {:w :x}) (. {:x :missing}) (. {:y :z}))"]=nil,
        -- just a boring old set+fn combo
        ["(require-macros \"test-macros\")\
          (defn1 hui [x y] (global z (+ x y))) (hui 8 4) z"]=12,
        -- macros with mangled names
        ["(require-macros \"test-macros\")\
          (->1 9 (+ 2) (* 11))"]=121,
        -- macros loaded in function scope shouldn't leak to other functions
        ["((fn [] (require-macros \"test-macros\") (global x1 (->1 99 (+ 31)))))\
          (pcall (fn [] (global x1 (->1 23 (+ 1)))))\
          x1"]=130,
        -- special form
        [ [[(eval-compiler
             (tset _SPECIALS "reverse-it" (fn [ast scope parent opts]
               (tset ast 1 "do")
               (for [i 2 (math.ceil (/ (# ast) 2))]
                 (let [a (. ast i) b (. ast (- (# ast) (- i 2)))]
                   (tset ast (- (# ast) (- i 2)) a)
                   (tset ast i b)))
               (_SPECIALS.do ast scope parent opts))))
           (reverse-it 1 2 3 4 5 6)]]]=1,
        -- nesting quote can only happen in the compiler
        ["(eval-compiler (set tbl.nest ``nest))\
          (tostring tbl.nest)"]="(quote, nest)",
        -- inline macros
        ["(macros {:plus (fn [x y] `(+ @x @y))}) (plus 9 9)"]=18,
    },
    match = {
        -- basic literal
        ["(match (+ 1 6) 7 8)"]=8,
        -- actually return the one that matches
        ["(match (+ 1 6) 7 8 8 1 9 2)"]=8,
        -- string literals? and values that come from locals?
        ["(let [s :hey] (match s :wat :no :hey :yes))"]="yes",
        -- tables please
        ["(match [:a :b :c] [a b c] (.. b :eee))"]="beee",
        -- tables with literals in them
        ["(match [:a :b :c] [1 t d] :no [a b :d] :NO [a b :c] b)"]="b",
        -- nested tables
        ["(match [:a [:b :c]] [a b :c] :no [:a [:b c]] c)"]="c",
        -- non-sequential tables
        ["(match {:a 1 :b 2} {:c 3} :no {:a n} n)"]=1,
        -- nested non-sequential
        ["(match [:a {:b 8}] [a b :c] :no [:a {:b b}] b)"]=8,
        -- unification
        ["(let [k :k] (match [5 :k] :b :no [n k] n))"]=5,
        -- length mismatch
        ["(match [9 5] [a b c] :three [a b] (+ a b))"]=14,
        -- 3rd arg may be nil here
        ["(match [9 5] [a b ?c] :three [a b] (+ a b))"]="three",
        -- no double-eval
        ["(var x 1) (fn i [] (set x (+ x 1)) x) (match (i) 4 :N 3 :n 2 :y)"]="y",
        -- multi-valued
        ["(match (values 5 9) 9 :no (a b) (+ a b))"]=14,
        -- multi-valued with nil
        ["(match (values nil :nonnil) (true _) :no (nil b) b)"]="nonnil",
        -- error values
        ["(match (io.open \"/does/not/exist\") (nil msg) :err f f)"]="err",
        -- last clause becomes default
        ["(match [1 2 3] [3 2 1] :no [2 9 1] :NO :default)"]="default",
        -- intra-pattern unification
        ["(match [1 2 3] [x y x] :no [x y z] :yes)"]="yes",
        ["(match [1 2 1] [x y x] :yes)"]="yes",
        ["(match (values 1 [1 2]) (x [x x]) :no (x [x y]) :yes)"]="yes",
        -- external unification
        ["(let [x 95] (match [52 85 95] [x y z] :nope [a b x] :yes))"]="yes",
        -- deep nested unification
        ["(match [1 2 [[3]]] [x y [[x]]] :no [x y z] :yes)"]="yes",
        ["(match [1 2 [[1]]] [x y [z]] (. z 1))"]=1,
        -- _ wildcard
        ["(match [1 2] [_ _] :wildcard)"]="wildcard",
        -- rest args
        ["(match [1 2 3] [a & b] (+ a (. b 1) (. b 2)))"]=6,
        ["(match [1] [a & b] (# b))"]=0,
    }
}

for name, tests in pairs(cases) do
    print("Running tests for " .. name .. "...")
    for code, expected in pairs(tests) do
        local ok, res = pcall(fennel.eval, code, {allowedGlobals = false})
        if not ok then
            err = err + 1
            print(" Error: " .. res .. " in: ".. fennel.compile(code))
        else
            if expected ~= res then
                fail = fail + 1
                print(" Expected " .. view(res) .. " to be " .. view(expected))
            else
                pass = pass + 1
            end
        end
    end
end

---- fennelview tests ----

local function count(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

local function table_equal(a, b, deep_equal)
    local miss_a, miss_b = {}, {}
    for k in pairs(a) do
        if deep_equal(a[k], b[k]) then a[k], b[k] = nil, nil end
    end
    for k, v in pairs(a) do
        if type(k) ~= "table" then miss_a[view(k)] = v end
    end
    for k, v in pairs(b) do
        if type(k) ~= "table" then miss_b[view(k)] = v end
    end
    return (count(a) == count(b)) or deep_equal(miss_a, miss_b)
end

local function deep_equal(a, b)
    if (a ~= a) or (b ~= b) then return true end -- don't fail on nan
    if type(a) == type(b) then
        if type(a) == "table" then return table_equal(a, b, deep_equal) end
        return tostring(a) == tostring(b)
    end
end

print("Running tests for fennelview...")
for _ = 1, 16 do
    local item = generate()
    local ok, viewed = pcall(view, item)
    if ok then
        local ok2, round_tripped = pcall(fennel.eval, viewed)
        if(ok2) then
            if deep_equal(item, round_tripped) then
                pass = pass + 1
            else
                print("Expected " .. viewed .. " to round-trip thru view/eval: "
                          .. tostring(round_tripped))
                fail = fail + 1
            end
        else
            print(" Error loading viewed item: " .. viewed, round_tripped)
            err = err + 1
        end
    else
        print(" Error viewing " .. tostring(item))
        err = err + 1
    end
end

---- tests for compilation failures ----

local compile_failures = {
    ["(f"]="expected closing delimiter %) in unknown:1",
    ["\n\n(+))"]="unexpected closing delimiter in unknown:3",
    ["(fn)"]="expected vector arg list",
    ["(fn [12])"]="expected symbol for function parameter",
    ["(fn [:huh] 4)"]="expected symbol for function parameter",
    ["(fn [false] 4)"]="expected symbol for function parameter",
    ["(fn [nil] 4)"]="expected symbol for function parameter",
    ["(lambda [x])"]="missing body",
    ["(let [x 1])"]="missing body",
    ["(let [x 1 y] 8)"]="expected even number of name/value bindings",
    ["(let [:x 1] 1)"]="unable to destructure",
    ["(let [false 1] 9)"]="unable to destructure false",
    ["(let [nil 1] 9)"]="unable to destructure nil",
    ["(let [[a & c d] [1 2]] c)"]="rest argument in final position",
    ["(set a 19)"]="error in 'set' unknown:1: expected local var a",
    ["(set [a b c] [1 2 3]) (+ a b c)"]="expected local var",
    ["(let [x 1] (set-forcibly! x 2) (set x 3) x)"]="expected local var",
    ["(not true false)"]="expected one argument",
    ["\n\n(let [x.y 9] nil)"]="unknown:3: did not expect multi",
    ["()"]="expected a function to call",
    ["(789)"]="789.*cannot call literal value",
    ["(fn [] [...])"]="unexpected vararg",
    -- line numbers
    ["(set)"]="Compile error in 'set' unknown:1: expected name and value",
    ["(let [b 9\nq (.)] q)"]="2: expected table argument",
    ["(do\n\n\n(each \n[x 34 (pairs {})] 21))"]="4: expected iterator symbol",
    ["(fn []\n(for [32 34 32] 21))"]="2: expected iterator symbol",
    ["\n\n(let [f (lambda []\n(local))] (f))"]="4: expected name and value",
    ["(do\n\n\n(each \n[x (pairs {})] (when)))"]="when' unknown:5:",
    -- macro errors have macro names in them
    ["\n(when)"]="Compile error in .when. unknown:2",
    -- strict about unknown global reference
    ["(hey)"]="unknown global",
    ["(fn global-caller [] (hey))"]="unknown global",
    ["(let [bl 8 a bcd] nil)"]="unknown global",
    ["(let [t {:a 1}] (+ t.a BAD))"]="BAD",
    ["(each [k v (pairs {})] (BAD k v))"]="BAD",
    ["(global good (fn [] nil)) (good) (BAD)"]="BAD",
    ["(global + 1)"]="overshadowed",
    ["(global // 1)"]="overshadowed",
    ["(global let 1)"]="overshadowed",
    ["(global - 1)"]="overshadowed",
    ["(let [global 1] 1)"]="overshadowed",
    ["(fn global [] 1)"]="overshadowed",
    ["(match [1 2 3] [a & b c] nil)"]="rest argument in final position",
}

print("Running tests for compile errors...")
for code, expected_msg in pairs(compile_failures) do
    local ok, msg = pcall(fennel.compileString, code, {allowedGlobals = {"pairs"}})
    if(ok) then
        fail = fail + 1
        print(" Expected failure when compiling " .. code .. ": " .. msg)
    elseif(not msg:match(expected_msg)) then
        fail = fail + 1
        print(" Expected " .. expected_msg .. " when compiling " .. code ..
                  " but got " .. msg)
    end
end

---- mangling and unmangling ----

-- Mapping from any string to Lua identifiers. (in practice, will only be from
-- fennel identifiers to lua, should be general for programatically created
-- symbols)

local mangling_tests = {
    ['a'] = 'a',
    ['a_3'] = 'a_3',
    ['3'] = '__fnl_global__3', -- a fennel symbol would usually not be a number
    ['a-b-c'] = '__fnl_global__a_2db_2dc',
    ['a_b-c'] = '__fnl_global__a_5fb_2dc',
}

print("Running tests for mangling / unmangling...")
for k, v in pairs(mangling_tests) do
    local manglek = fennel.mangle(k)
    local unmanglev = fennel.unmangle(v)
    if v ~= manglek then
        print(" Expected fennel.mangle(" .. k .. ") to be " .. v ..
                  ", got " .. manglek)
        fail = fail + 1
    else
        pass = pass + 1
    end
    if k ~= unmanglev then
        print(" Expected fennel.unmangle(" .. v .. ") to be " .. k ..
                  ", got " .. unmanglev)
        fail = fail + 1
    else
        pass = pass + 1
    end
end

---- quoting and unquoting ----

local quoting_tests = {
    ['`:abcde'] = {"return \"abcde\"", "simple string quoting"},
    ['@a'] = {"return unquote(a)",
              "unquote outside quote is simply passed thru"},
    ['`[1 2 @(+ 1 2) 4]'] = {
        "return {1, 2, (1 + 2), 4}",
        "unquote inside quote leads to evaluation"
    },
    ['(let [a (+ 2 3)] `[:hey @(+ a a)])'] = {
        "local a = (2 + 3)\nreturn {\"hey\", (a + a)}",
        "unquote inside other forms"
    },
    ['`[:a :b :c]'] = {
      "return {\"a\", \"b\", \"c\"}",
      "quoted sequential table"
    },
    ['`{:a 5 :b 9}'] = {
        {
            ["return {[\"a\"]=5, [\"b\"]=9}"] = true,
            ["return {[\"b\"]=9, [\"a\"]=5}"] = true,
        },
      "quoted keyed table"
    }
}

print("Running tests for quote / unquote...")
for k, v in pairs(quoting_tests) do
    local compiled = fennel.compileString(k, {allowedGlobals=false})
    local accepted, ans = v[1]
    if type(accepted) ~= 'table' then
        ans = accepted
        accepted = {}
        accepted[ans] = true
    end
    local message = v[2]
    local errorformat = "While testing %s\n" ..
        "Expected fennel.compileString(\"%s\") to be \"%s\" , got \"%s\""
    if accepted[compiled] then
        pass = pass + 1
    else
        print(errorformat:format(message, k, ans, compiled))
        fail = fail + 1
    end
end

---- misc one-off tests ----

if pcall(fennel.eval, "(->1 1 (+ 4))", {allowedGlobals = false}) then
    fail = fail + 1
    print(" Expected require-macros not leak into next evaluation.")
end

if pcall(fennel.eval, "`(hey)", {allowedGlobals = false}) then
    fail = fail + 1
    print(" Expected quoting lists to fail at runtime.")
end

if pcall(fennel.eval, "`[hey]", {allowedGlobals = false}) then
    fail = fail + 1
    print(" Expected quoting syms to fail at runtime.")
end

if not pcall(fennel.eval, "(.. hello-world :w)",
             {env = {["hello-world"] = "hi"}}) then
    fail = fail + 1
    print(" Expected global mangling to work.")
end

local g = {["hello-world"] = "hi", tbl = _G.tbl,
    -- tragically lua 5.1 does not have metatable-aware pairs so we fake it here
    pairs = function(t)
        local mt = getmetatable(t)
        if(mt and mt.__pairs) then
            return mt.__pairs(t)
        else
            return pairs(t)
        end
    end}
g._G = g

if(not pcall(fennel.eval, "(each [k (pairs _G)] (tset tbl k true))", {env = g})
   or not _G.tbl["hello-world"]) then
    fail = fail + 1
    print(" Expected wrapped _G to support env iteration.")
end

do
    local e = {}
    if (not pcall(fennel.eval, "(global x-x 42)", {env = e})
        or not pcall(fennel.eval, "x-x", {env = e})) then
        fail = fail + 1
        print(" Expected mangled globals to be accessible across eval invocations.")
    end
end


print(string.format("\n%s passes, %s failures, %s errors.", pass, fail, err))
if(fail > 0 or err > 0) then os.exit(1) end
