# SwiftPandas Pipe DSL — Ontology & Grammar for LLMs

This document teaches a large language model to translate natural-language data
requests into valid **swiftpandas pipe-DSL** pipelines. It is written to be
pasted into an LLM prompt (or used as retrieval context) and is the single
source of truth for what the language can and cannot express. Section 5
contains ready-to-use prompt templates built from this material.

The DSL described here is the text pipeline language accepted by the
`swiftpandas` CLI and daemon:

```bash
swiftpandas -i sales.csv -o out.csv -c 'filter(revenue > 10000) | groupby(region) | agg(sum:revenue)'
```

It is parsed by `Sources/SwiftPandasCLI/DSL/Parser.swift` and executed by
`Sources/SwiftPandasCLI/Transforms/TransformRunner.swift`. Every claim in this
document reflects the actual parser and runtime, not aspiration.

---

## 1. Ontology — the data model

### 1.1 The DataFrame

The only data structure in the language is the **DataFrame**: a 2-dimensional
table of named, ordered, homogeneously-typed columns. A pipeline is a function
from one DataFrame to another. There are no scalars, no standalone lists, no
variables, and no second table — every operation consumes the whole current
frame and produces a whole new frame.

```
        DataFrame in                      DataFrame out
  ┌──────┬─────────┬────────┐      ┌────────┬─────────┐
  │ name │ region  │ revenue│  →   │ region │ revenue │
  │ …    │ …       │ …      │      │ …      │ …       │
  └──────┴─────────┴────────┘      └────────┴─────────┘
```

### 1.2 Column types (dtypes)

Every column has exactly one of four storable dtypes:

| dtype     | What it holds                  | Literal form in the DSL      |
|-----------|--------------------------------|------------------------------|
| `float64` | 64-bit floats (**the default for anything numeric**) | `3.14`, `-0.5`, `100.0` |
| `int64`   | 64-bit integers                | `42`, `-7`                   |
| `bool`    | true/false                     | (no bool literals in the DSL)|
| `string`  | UTF-8 text                     | `"active"` or bare `active`  |

Critical facts:

- **Numbers default to float64.** CSV columns that look numeric are read as
  float64 unless every value parses as an integer.
- **There is no datetime dtype.** Dates live in string columns. Comparisons on
  them are lexicographic string comparisons — which work correctly for
  ISO-8601 dates (`"2026-07-18" > "2026-01-01"` is true), and incorrectly for
  formats like `18/07/2026`. Never claim date arithmetic (add days, extract
  month, etc.) is possible.
- Comparing a numeric column to a number, or a string column to a string, is
  well-typed. Cross-type comparisons match nothing or raise an error.

### 1.3 Missing data (NA)

Missing values are first-class ("NA"), tracked by a validity bitmask:

- **NA fails every comparison.** `filter(x > 0)` and `filter(x <= 0)` *both*
  drop rows where `x` is NA. There is no `is null` / `is not null` predicate.
- **Aggregations skip NA** (pandas `skipna=True` semantics): `mean` averages
  only the valid values, `count` counts group rows.
- **NA sorts last** regardless of sort direction.
- The DSL has no `fillna` / `dropna` operation.

### 1.4 The pipeline model

A program is a sequence of operations joined by `|`, evaluated **strictly left
to right**. Each stage sees only the output of the previous stage:

```
filter(status == "active") | groupby(region) | agg(sum:revenue) | sort(revenue, desc) | head(5)
```

Consequences the LLM must internalize:

1. **Column references resolve against the *current* frame.** After
   `rename(revenue -> total)`, later stages must say `total`. After `select`
   or `drop`, removed columns are gone. After `derive(margin = ...)`, the new
   column is usable downstream.
2. **After `agg`, the frame collapses.** Only the group-key column(s) and the
   aggregated column(s) survive; every other column is gone.
3. **Filter before you aggregate.** A filter after `agg` applies to the
   aggregated result (which is sometimes what you want — "regions whose total
   revenue exceeds X" — but usually the filter belongs before the `groupby`).
4. **Order changes cost.** Prefer `filter` early (shrinks the data) and
   `sort`/`head` late.

### 1.5 Execution context

The pipeline is run by the CLI (`swiftpandas -i in.csv -o out.csv -c "<pipeline>"`),
by the resident daemon, or from a JSON transform file (`-f transforms.json`,
an array of `{"op": ..., "args": ...}` objects with the same semantics).
Useful flags: `--sep ';'` (input separator), `--dry-run` (parse and validate
without executing), `--verbose` (per-step row/column/time log). An LLM
generating pipelines only needs to emit the pipeline string.

---

## 2. Grammar — lexical rules

The tokenizer is whitespace-insensitive: spaces and newlines between tokens
are ignored, so a pipeline may be written on one line or split across lines
at the `|`.

| Token            | Rule                                                                 |
|------------------|----------------------------------------------------------------------|
| identifier       | `[A-Za-z_][A-Za-z0-9_]*` — column names, operation names, keywords. **No spaces, dots, or hyphens.** A column literally named `unit price` cannot be referenced. |
| string literal   | Double quotes only: `"active"`. Backslash escapes the next character: `"say \"hi\""`. Single quotes are **not** string delimiters. |
| integer          | `42`, `-7` (a minus is a negative sign when it follows an operator, `(`, `,`, `:`, `=`, `|`, or starts the input; otherwise it is subtraction) |
| float            | `3.14`, `-0.5` (must contain a `.`; no exponent notation, no `1e6`) |
| comparison ops   | `>` `>=` `<` `<=` `==` `!=` |
| arithmetic ops   | `+` `-` `*` `/` (used only inside `derive`) |
| punctuation      | `(` `)` `,` `:` `->` `=` `\|` |
| comment          | `#` to end of line (useful in multi-line pipeline files) |

String values in `filter` may also be written as **bare identifiers**:
`filter(status == active)` equals `filter(status == "active")`. Always prefer
quotes — a bare value only works when it happens to be a valid identifier
(`filter(city == New York)` is a parse error; `filter(city == "New York")`
is correct).

### 2.1 Pipeline grammar (EBNF)

```ebnf
pipeline   = operation , { "|" , operation } ;
operation  = filter | sort | groupby | agg | select | drop
           | rename | head | tail | round | derive | cast ;

filter     = "filter"  , "(" , column , ( compop , value
                                        | "contains" , string ) , ")" ;
compop     = ">" | ">=" | "<" | "<=" | "==" | "!=" ;
value      = number | integer | string | identifier ;

sort       = "sort"    , "(" , sortspec , { "," , sortspec } , ")" ;
sortspec   = column , [ [","] , ( "asc" | "desc" ) ] ;

groupby    = "groupby" , "(" , column , { "," , column } , ")" ;
agg        = "agg"     , "(" , aggspec , { "," , aggspec } , ")" ;
aggspec    = aggfn , ":" , column ;
aggfn      = "sum" | "mean" | "count" | "min" | "max" ;   (* see §3.4 *)

select     = "select"  , "(" , column , { "," , column } , ")" ;
drop       = "drop"    , "(" , column , { "," , column } , ")" ;
rename     = "rename"  , "(" , column , "->" , column , ")" ;
head       = "head"    , "(" , integer , ")" ;
tail       = "tail"    , "(" , integer , ")" ;
round      = "round"   , "(" , column , "," , integer , ")" ;
derive     = "derive"  , "(" , column , "=" , expr , ")" ;
expr       = term  , { ("+" | "-") , term } ;
term       = atom  , { ("*" | "/") , atom } ;
atom       = number | integer | string | column | "(" , expr , ")" ;
cast       = "cast"    , "(" , column , "," , casttype , ")" ;
casttype   = "Int" | "Double" | "Float" | "String" ;
```

There are exactly **12 operations**. Anything else (`merge`, `join`,
`distinct`, `fillna`, `pivot`, `limit`, `where`, …) is a parse error:
`unknown operation`.

---

## 3. Operation reference

Each entry: syntax, semantics, pandas equivalent, examples, pitfalls.

### 3.1 `filter` — keep rows matching one condition

```
filter(column op value)
filter(column contains "substring")
```

- `op` ∈ `>` `>=` `<` `<=` `==` `!=`. Numeric ops on numeric columns; `==`,
  `!=`, `contains` on string columns.
- `contains` is a case-sensitive substring test (pandas `.str.contains`,
  no regex). Its value must be a string.
- pandas: `df[df["revenue"] > 10000]`, `df[df["name"].str.contains("smith")]`

```text
filter(revenue > 10000)
filter(status == "active")
filter(temperature <= -5)
filter(product contains "Pro")
filter(discount != 0)
```

**One condition per `filter`. There is no `and`/`or`/`&&`/`||`/`not`.**

- **AND** — chain filters:
  `filter(revenue > 10000) | filter(status == "active")`
- **Range ("between 100 and 500")** — two filters:
  `filter(revenue >= 100) | filter(revenue <= 500)`
- **OR across values or columns** — **not expressible** in a single pipeline.
  Do not invent syntax; answer `UNSUPPORTED` (§5). (The only special case:
  "not equal to A" is `!=`, and an OR that enumerates *all but one* value of
  a column can sometimes be rewritten as `!=`.)

Pitfalls: `filter(10000 < revenue)` is invalid — the column must come first.
`filter(a > b)` comparing two columns is invalid — the right side must be a
literal. `filter(x is null)` does not exist.

### 3.2 `sort` — order rows

```
sort(column)                  # ascending (default)
sort(column, desc)            # or: sort(column desc)
sort(col1 desc, col2 asc)     # multi-column: first key wins, ties broken by next
```

- Directions: `asc`, `desc`. NA values always sort last.
- pandas: `df.sort_values(["col1","col2"], ascending=[False, True])`

```text
sort(revenue, desc)
sort(region asc, revenue desc)
sort(last_name, first_name)
```

Pitfall: `sort(revenue, descending)` / `sort(-revenue)` are invalid — the
only direction keywords are `asc` and `desc`.

### 3.3 `groupby` — declare grouping keys

```
groupby(col)
groupby(col1, col2)
```

`groupby` does nothing by itself — it **must be immediately followed by
`agg`** as the very next stage, otherwise the pipeline errors
(`agg without groupby` / `groupby without agg`). One sanctioned exception: a
pipeline may *end* with a bare `groupby`, which implicitly performs a count —
but prefer the explicit `groupby(...) | agg(count:col)` form.

- pandas: `df.groupby(["region","quarter"])`

### 3.4 `agg` — aggregate each group

```
agg(fn:column)
agg(fn1:col1, fn2:col2, ...)
```

- Allowed functions: **`sum`, `mean`, `count`, `min`, `max`** — nothing else.
  ⚠️ The parser also *accepts* `std` and `median`, but the runtime silently
  computes `mean` instead. **Never emit `std` or `median`**; treat per-group
  standard deviation or median as `UNSUPPORTED`.
- **Every agg target must be a numeric column that is not a group key** —
  this includes `count`. `count` counts rows per group regardless of which
  column it names, but naming a group key or a string column crashes the
  runtime. So "how many rows per region" is
  `groupby(region) | agg(count:revenue)` (any numeric non-key column), never
  `agg(count:region)`.
- **Output shape:** the result frame contains the group-key column(s) followed
  by one column per agg spec. Each aggregated column **keeps its source
  column name** (there is no `sum_revenue` auto-naming; a `count:revenue`
  puts the counts in a column still called `revenue`) — use `rename`
  afterwards for a truthful name. All other columns are dropped.
- Aggregating the same column with two functions (`agg(sum:x, mean:x)`) is
  possible but both outputs would collide on the name `x` — avoid it, or it
  will produce a single column.
- pandas: `df.groupby("region").agg(revenue=("revenue","sum"))`

```text
groupby(region) | agg(sum:revenue)
groupby(region, quarter) | agg(sum:revenue, mean:margin, count:transactions)
groupby(department) | agg(mean:salary) | rename(salary -> avg_salary)
```

### 3.5 `select` — keep only these columns

```
select(col1, col2, ...)
```

Keeps the listed columns in the listed order, drops the rest.
pandas: `df[["name","salary"]]`

```text
select(name, department, salary)
```

### 3.6 `drop` — remove columns

```
drop(col1, col2, ...)
```

pandas: `df.drop(columns=[...])`

```text
drop(internal_id, notes)
```

### 3.7 `rename` — rename one column

```
rename(old_name -> new_name)
```

**Exactly one pair per call.** Rename several columns by chaining:

```text
rename(revenue -> total_revenue) | rename(margin -> avg_margin)
```

pandas: `df.rename(columns={"revenue": "total_revenue"})`

Pitfall: `rename(a -> b, c -> d)` is not supported; the arrow is `->`, not
`=>` or `=`.

### 3.8 `head` / `tail` — first / last N rows

```
head(10)
tail(5)
```

Argument is a single positive integer literal. N larger than the row count is
safely clamped. pandas: `df.head(10)` / `df.tail(5)`.

"Top N by X" is always `sort(X, desc) | head(N)`; "bottom N by X" is
`sort(X) | head(N)` (or `sort(X, desc) | tail(N)`).

### 3.9 `round` — round a numeric column in place

```
round(column, decimals)
```

Replaces the column with values rounded to `decimals` places (half away from
zero). Typically the last step after a `derive` or `agg(mean:...)`.
pandas: `df["x"] = df["x"].round(2)`

```text
groupby(city) | agg(mean:price) | round(price, 2)
```

### 3.10 `derive` — compute a new column

```
derive(new_column = expression)
```

- The expression supports column references, numeric literals, `+ - * /`, and
  parentheses, with normal precedence (`*` `/` bind tighter than `+` `-`).
- **No functions** — no `abs`, `log`, `if`, `min`, string concatenation, or
  comparisons inside `derive`.
- All referenced columns must be numeric (float64/int64). A string literal on
  the right creates a constant string column (`derive(source = "import")`),
  but strings cannot be combined with `+`.
- If `new_column` already exists it is **replaced**; otherwise it is appended.
- pandas: `df["margin_pct"] = df["margin"] / df["revenue"] * 100`

```text
derive(total = price * quantity)
derive(margin_pct = margin / revenue * 100) | round(margin_pct, 1)
derive(fahrenheit = celsius * 9 / 5 + 32)
derive(discounted = price * (1 - discount))
```

### 3.11 `cast` — convert a column's type

```
cast(column, Type)        # Type ∈ Int | Double | Float | String
```

Type names are capitalized Swift-style and case-sensitive. `Float` behaves as
`Double`. `cast(x, Int)` truncates toward zero; numeric strings are parsed;
unparseable values become NA. `cast(x, String)` stringifies every value.
pandas: `df["x"].astype(int)`

```text
cast(user_id, Int)
cast(zipcode, String)
cast(amount, Double)
```

### 3.12 Out of scope — do not invent syntax for these

The DSL cannot express: **joins/merges** (single-table only), **OR
conditions**, **null checks / fillna / dropna**, **distinct /
drop-duplicates / value counts**, **per-group std / median / quantiles**,
**date arithmetic or date part extraction**, **string transforms**
(upper/lower/trim/concat/regex), **pivot / melt / transpose**, **window
functions / cumulative sums / rank**, **sampling**, **comparing two columns
in a filter**. When a request requires any of these, the correct output is
`UNSUPPORTED: <reason>` — never an invented operation.

(Many of these *do* exist in the SwiftPandas Swift library API — `merge`,
`dropDuplicates`, `valueCounts`, `fillNA`, `median`, `cumsum` — just not in
the pipe DSL. See `README.md` and `docs/TUTORIAL.md`.)

---

## 4. Natural-language → DSL cookbook

Assume this schema for the examples:
`sales(region:string, quarter:string, product:string, status:string,
revenue:float64, margin:float64, quantity:int64, transactions:int64)`

| User request | Pipeline |
|---|---|
| "rows where revenue is over 10k" | `filter(revenue > 10000)` |
| "only active records" | `filter(status == "active")` |
| "everything except cancelled orders" | `filter(status != "cancelled")` |
| "products with 'Pro' in the name" | `filter(product contains "Pro")` |
| "revenue between 100 and 500" | `filter(revenue >= 100) \| filter(revenue <= 500)` |
| "active orders over 10k" (AND) | `filter(status == "active") \| filter(revenue > 10000)` |
| "sort by revenue, biggest first" | `sort(revenue, desc)` |
| "top 10 rows by revenue" | `sort(revenue, desc) \| head(10)` |
| "5 smallest margins" | `sort(margin) \| head(5)` |
| "total revenue per region" | `groupby(region) \| agg(sum:revenue)` |
| "average margin by region and quarter" | `groupby(region, quarter) \| agg(mean:margin)` |
| "how many sales per product" | `groupby(product) \| agg(count:revenue) \| rename(revenue -> sales)` |
| "top 3 regions by total revenue" | `groupby(region) \| agg(sum:revenue) \| sort(revenue, desc) \| head(3)` |
| "regions with total revenue above 1M" | `groupby(region) \| agg(sum:revenue) \| filter(revenue > 1000000)` |
| "just the product and revenue columns" | `select(product, revenue)` |
| "get rid of the transactions column" | `drop(transactions)` |
| "call the revenue column total_revenue" | `rename(revenue -> total_revenue)` |
| "add a per-unit price column" | `derive(unit_price = revenue / quantity)` |
| "margin as a % of revenue, 1 decimal" | `derive(margin_pct = margin / revenue * 100) \| round(margin_pct, 1)` |
| "make quantity a whole number" | `cast(quantity, Int)` |
| "first 20 rows" | `head(20)` |
| "quarterly revenue report: active only, totals by region+quarter, nicely named" | `filter(status == "active") \| groupby(region, quarter) \| agg(sum:revenue, mean:margin) \| sort(revenue, desc) \| rename(revenue -> total_revenue) \| rename(margin -> avg_margin) \| round(avg_margin, 3)` |

Requests that must be refused (`UNSUPPORTED: …`):

| User request | Correct response |
|---|---|
| "revenue over 10k **or** margin over 50%" | `UNSUPPORTED: OR conditions are not expressible; run two separate pipelines.` |
| "**median** salary per department" | `UNSUPPORTED: per-group median is not available (agg supports sum, mean, count, min, max).` |
| "**join** sales with the regions table" | `UNSUPPORTED: the pipeline operates on a single table; joins are not available in the DSL.` |
| "rows where the date is **in March**" | `UNSUPPORTED: no date operations; only whole-string comparison on date columns (ISO ranges work: filter(date >= "2026-03-01") \| filter(date < "2026-04-01")).` |
| "**deduplicate** by customer id" | `UNSUPPORTED: distinct/drop-duplicates is not available in the DSL.` |
| "rows where discount is **missing**" | `UNSUPPORTED: there is no null-check predicate.` |
| "**uppercase** the region names" | `UNSUPPORTED: no string transformation operations.` |

Note the date case: if the dates are ISO-8601 (`YYYY-MM-DD`), a range *can*
be expressed with two string-comparison filters — offer that form when the
schema's sample values confirm ISO format; otherwise refuse.

---

## 5. Ready-to-use prompts

### 5.1 Full system prompt

Fill `{{schema}}` with the table's column names, dtypes, and 2–3 sample rows;
`{{request}}` with the user's words.

````text
You translate natural-language data questions into swiftpandas pipe-DSL
pipelines. You output ONLY the pipeline — a single line, no backticks, no
explanation — or a single line starting with "UNSUPPORTED: " when the request
cannot be expressed.

THE LANGUAGE
A pipeline is 1+ operations joined by "|", applied left to right to one
table. Exactly 12 operations exist:

  filter(col > value)          keep rows; ops: > >= < <= == != ; strings use
  filter(col == "text")        double quotes; also: filter(col contains "sub")
  sort(col, desc)              asc (default) | desc; multi: sort(a desc, b asc)
  groupby(col1, col2)          MUST be immediately followed by agg(...)
  agg(fn:col, ...)             fn ∈ sum | mean | count | min | max — ONLY these
  select(col1, col2)           keep only these columns
  drop(col1, col2)             remove these columns
  rename(old -> new)           one pair per call; chain for more
  head(n) / tail(n)            first / last n rows
  round(col, decimals)         round a numeric column in place
  derive(new = expr)           arithmetic only: cols, numbers, + - * / ( )
  cast(col, Int|Double|Float|String)

HARD RULES
1. One condition per filter. AND = chain filters. OR is impossible → UNSUPPORTED.
2. Never use std or median in agg → UNSUPPORTED for per-group std/median.
3. Every agg target — including count — must be a NUMERIC column that is NOT
   a group key. "count per G" = groupby(G) | agg(count:N) | rename(N -> n_rows)
   where N is any numeric non-key column.
4. After agg, only the group-key column(s) and aggregated column(s) exist,
   and aggregated columns KEEP their original names (count:N leaves counts in
   a column named N). Reference only those downstream; rename for truthful names.
5. After rename/select/drop/derive, use the current column names.
6. Use EXACTLY the column names from the schema. Never invent columns.
7. Quote string values: filter(city == "New York"). Numbers are unquoted.
8. Column names are single identifiers (letters, digits, _). A filter compares
   a column to a literal — never column vs column, never literal-first.
9. "top N by X" = sort(X, desc) | head(N).
10. No joins, null checks, dedup, date/string functions, pivots, window
    functions, or sampling → UNSUPPORTED with a one-clause reason.
11. There is no datetime type. Dates are strings; if sample values are ISO
    (YYYY-MM-DD), express date ranges as two string filters, else UNSUPPORTED.
12. Filter before groupby unless the request is about the aggregated values.

SCHEMA
{{schema}}

REQUEST
{{request}}
````

### 5.2 Compact system prompt

A token-lean variant for small models or high-volume translation:

````text
Output only a swiftpandas pipeline (one line, no markdown) or "UNSUPPORTED: <reason>".
Ops (only these 12): filter(col op val | col contains "s") with op > >= < <= == != ·
sort(col[, asc|desc], ...) · groupby(cols)|agg(fn:col,...) fn∈{sum,mean,count,min,max} ·
select(cols) · drop(cols) · rename(old -> new) · head(n) · tail(n) ·
round(col,dec) · derive(new = arith of cols/nums + - * / ()) · cast(col, Int|Double|Float|String).
Rules: one condition per filter; AND=chained filters; OR/joins/median/std/null-checks/
dedup/date-or-string-functions → UNSUPPORTED. groupby must be followed by agg; agg targets
(incl. count) must be numeric non-key columns; after agg only key+agg columns remain,
keeping original names. Quote strings, use exact schema names.
Schema: {{schema}}
Request: {{request}}
````

### 5.3 Few-shot examples block

Append after the system prompt (or send as prior user/assistant turns).
Schema for these shots:
`orders(customer:string, city:string, status:string, order_date:string, amount:float64, items:int64)`

````text
Q: show me orders over $500
A: filter(amount > 500)

Q: completed orders in Chicago, biggest first
A: filter(status == "completed") | filter(city == "Chicago") | sort(amount, desc)

Q: what are my 5 biggest orders?
A: sort(amount, desc) | head(5)

Q: total order value per city
A: groupby(city) | agg(sum:amount)

Q: average order size by city and status, call it avg_amount
A: groupby(city, status) | agg(mean:amount) | rename(amount -> avg_amount)

Q: how many orders per customer, top 10 customers
A: groupby(customer) | agg(count:amount) | rename(amount -> orders) | sort(orders, desc) | head(10)

Q: add a per-item price column rounded to 2 decimals
A: derive(per_item = amount / items) | round(per_item, 2)

Q: orders from March 2026
A: filter(order_date >= "2026-03-01") | filter(order_date < "2026-04-01")

Q: orders from Chicago or Boston
A: UNSUPPORTED: OR conditions are not expressible; run one pipeline per city.

Q: median order value per city
A: UNSUPPORTED: per-group median is not available (agg supports sum, mean, count, min, max).
````

Note the count-per-customer shot: `count` must target a numeric non-key
column (`amount`), and the counts land in a column still called `amount` —
hence the immediate `rename(amount -> orders)` before sorting by it.

### 5.4 Repair prompt (second pass)

When the emitted pipeline fails to parse or run, a cheap second call usually
fixes it:

````text
The following swiftpandas pipeline failed. Using the same grammar rules and
schema you were given, output ONLY the corrected pipeline (one line), or
"UNSUPPORTED: <reason>" if the request cannot be expressed.

Pipeline: {{pipeline}}
Error: {{error_message}}
Original request: {{request}}
````

Validate cheaply before executing: `swiftpandas -i data.csv --dry-run -c "<pipeline>"`
parses and type-checks without running the transform.

---

## 6. Error appendix

Errors the CLI can raise, with cause and fix — feed these to the repair
prompt in §5.4.

| Error message (pattern) | Cause | Fix |
|---|---|---|
| `Unknown operation: 'X'` | Operation name not one of the 12 (`where`, `limit`, `merge`, …) | Map to the real operation or return UNSUPPORTED |
| `Expected parentheses around arguments for 'X'` | Missing `(` `)` | Every operation takes parenthesized arguments |
| `filter requires: column operator value` | Too few tokens in filter | `filter(col > 5)` shape |
| `filter: expected comparison operator after column name` | Bad/missing operator (e.g. `=`, `in`, `&&`) | Use `> >= < <= == !=` or `contains` |
| `filter: unexpected value token` | Malformed value | Number, `"string"`, or bare identifier only |
| `agg: unknown function 'X'. Use: sum, mean, count, min, max, std, median` | Bad agg fn | Use `sum/mean/count/min/max` (never std/median — see §3.4) |
| `agg: expected ':' after function name` | Wrote `agg(sum revenue)` or `agg(sum(revenue))` | `agg(sum:revenue)` |
| `agg without a preceding groupby` / groupby not followed by agg | `agg` alone, or another op between `groupby` and `agg` | `groupby(...) \| agg(...)` must be adjacent |
| `rename: expected 'old_name -> new_name'` | Wrong arrow or multiple pairs | One `old -> new` per rename; chain renames |
| `head: expected a single integer` (also tail) | Non-integer or extra args | `head(10)` |
| `round: expected 'column, decimals'` | Missing comma/integer | `round(price, 2)` |
| `derive: expected 'column_name = expression'` | Missing `=` | `derive(total = price * qty)` |
| `derive: unexpected token in expression` | Function call or comparison inside derive | Arithmetic only: cols, numbers, `+ - * /`, parens |
| `cast: expected 'column, Type'` / `Invalid cast target` | Lowercase or unknown type | `Int`, `Double`, `Float`, `String` (capitalized) |
| `Unknown column: 'X'` | Column absent from the *current* frame (typo, or dropped/renamed/consumed by agg upstream) | Use schema names; track frame state through the pipeline (§1.4) |
| `Fatal error: Column 'X' not found` (process crash) | `agg` targeted a group-key or string column (e.g. `groupby(region) \| agg(count:region)`) | Agg targets — including `count` — must be numeric non-key columns (§3.4) |
| `Unterminated string literal` | Odd number of `"` | Close every quote; escape inner quotes as `\"` |
| `Unexpected character: 'X'` | Illegal char (`'`, `;`, `%`, `$`, …) | Strip units/symbols: `filter(price > 100)`, not `> $100` |
| `Empty pipeline` | Empty or comment-only command string | Emit at least one operation |
| `Type mismatch on column 'X'` | e.g. `contains` with a numeric value, numeric compare on a string column | Match literal type to the column's dtype |

---

*Generated against swiftpandas v0.7.0-beta. Grammar source:
`Sources/SwiftPandasCLI/DSL/{Token,Parser,Operation}.swift`; runtime:
`Sources/SwiftPandasCLI/Transforms/TransformRunner.swift`.*
