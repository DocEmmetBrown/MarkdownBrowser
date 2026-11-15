# Code Language Showcase

Short examples for checking native syntax highlighting in light and dark mode.
Each code fence names its language. Click a block to edit its Markdown source;
click another block to see the rendered highlighting again.

[Back to the sample README](README.md)

## Swift

```swift
struct Greeting {
    let name: String

    func render() -> String { "Hello, \(name)!" }
}

print(Greeting(name: "world").render())
```

## Rust

```rust
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

fn main() {
    let names = ["world", "Rust"];
    for name in names {
        println!("{}", greet(name));
    }
}
```

## C

```c
#include <stdio.h>

int main(void) {
    const char *name = "world";
    printf("Hello, %s!\n", name);
    return 0;
}
```

## C++

```cpp
#include <iostream>
#include <vector>

int main() {
    const std::vector<int> values{1, 2, 3};
    for (const auto value : values) {
        std::cout << value * 2 << '\n';
    }
}
```

## Objective-C

```objective-c
#import <Foundation/Foundation.h>

int main(void) {
    @autoreleasepool {
        NSArray<NSString *> *names = @[@"world", @"Objective-C"];
        for (NSString *name in names) {
            NSLog(@"Hello, %@!", name);
        }
    }
    return 0;
}
```

## C#

```cs
using System;

record Greeting(string Name)
{
    public string Render() => $"Hello, {Name}!";
}

class Program
{
    static void Main() => Console.WriteLine(new Greeting("world").Render());
}
```

## Go

```go
package main

import "fmt"

func main() {
    names := []string{"world", "Go"}
    for index, name := range names {
        fmt.Printf("%d: Hello, %s!\n", index, name)
    }
}
```

## Java

```java
public class Greeting {
    public static void main(String[] args) {
        var names = new String[] {"world", "Java"};
        for (String name : names) {
            System.out.printf("Hello, %s!%n", name);
        }
    }
}
```

## Kotlin

```kotlin
data class Greeting(val name: String) {
    fun render(): String = "Hello, $name!"
}

fun main() {
    listOf("world", "Kotlin")
        .map { Greeting(it).render() }
        .forEach(::println)
}
```

## Scala

```scala
object Greeting {
  def main(args: Array[String]): Unit = {
    val names = List("world", "Scala")
    names.map(name => s"Hello, $name!").foreach(println)
  }
}
```

## Python

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class Greeting:
    name: str

    def render(self) -> str:
        return f"Hello, {self.name}!"

print(Greeting("world").render())
```

## Ruby

```ruby
def greet(name)
  "Hello, #{name}!"
end

%w[world Ruby].each_with_index do |name, index|
  puts "#{index}: #{greet(name)}"
end
```

## Perl

```perl
use strict;
use warnings;

my @names = ("world", "Perl");
for my $name (@names) {
    print "Hello, $name!\n";
}
```

## PHP

```php
<?php
declare(strict_types=1);

function greet(string $name): string {
    return "Hello, {$name}!";
}

foreach (["world", "PHP"] as $name) {
    echo greet($name), PHP_EOL;
}
```

## JavaScript

```javascript
const greet = (name = "world") => `Hello, ${name}!`;
const names = ["world", "JavaScript"];

for (const [index, name] of names.entries()) {
  console.log(`${index}: ${greet(name)}`);
}
```

## TypeScript

```typescript
interface Greeting {
  readonly name: string;
  count?: number;
}

function render({ name, count = 1 }: Greeting): string[] {
  return Array.from({ length: count }, () => `Hello, ${name}!`);
}

console.log(render({ name: "world", count: 2 }));
```

## JSX

```jsx
import React from "react";

export default function Greeting({ name = "world" }) {
  return (
    <section className="greeting">
      <h1>Hello, {name}!</h1>
      <p>Rendered from JSX.</p>
    </section>
  );
}
```

## TSX

```tsx
import React from "react";

type Props = { name: string; excited?: boolean };

export function Greeting({ name, excited = true }: Props) {
  return <h1>Hello, {name}{excited ? "!" : "."}</h1>;
}
```

## Dart

```dart
class Greeting {
  final String name;
  const Greeting(this.name);

  String render() => 'Hello, $name!';
}

void main() {
  print(const Greeting('world').render());
}
```

## Lua

```lua
local function greet(name)
    return string.format("Hello, %s!", name)
end

for index, name in ipairs({ "world", "Lua" }) do
    print(index, greet(name))
end
```

## R

```r
greet <- function(name) {
  sprintf("Hello, %s!", name)
}

names <- c("world", "R")
messages <- vapply(names, greet, character(1))
print(messages)
```

## Julia

```julia
greet(name::AbstractString) = "Hello, $name!"

names = ["world", "Julia"]
for (index, name) in enumerate(names)
    println("$index: $(greet(name))")
end
```

## Haskell

```haskell
greet :: String -> String
greet name = "Hello, " ++ name ++ "!"

main :: IO ()
main = mapM_ (putStrLn . greet) ["world", "Haskell"]
```

## OCaml

```ocaml
let greet name = Printf.sprintf "Hello, %s!" name

let () =
  ["world"; "OCaml"]
  |> List.map greet
  |> List.iter print_endline
```

## Clojure

```clojure
(ns greeting.core)

(defn greet [name]
  (str "Hello, " name "!"))

(doseq [name ["world" "Clojure"]]
  (println (greet name)))
```

## Elixir

```elixir
defmodule Greeting do
  def render(name), do: "Hello, #{name}!"
end

["world", "Elixir"]
|> Enum.map(&Greeting.render/1)
|> Enum.each(&IO.puts/1)
```

## Erlang

```erlang
-module(greeting).
-export([main/0]).

greet(Name) ->
    io:format("Hello, ~s!~n", [Name]).

main() ->
    lists:foreach(fun greet/1, ["world", "Erlang"]).
```

## Bash

```bash
#!/usr/bin/env bash
set -euo pipefail

names=("world" "Bash")
for name in "${names[@]}"; do
  printf 'Hello, %s!\n' "$name"
done
```

## Fish

```fish
function greet --argument-names name
    printf 'Hello, %s!\n' "$name"
end

for name in world Fish
    greet "$name"
end
```

## SQL

```sql
WITH scores(name, points) AS (
    VALUES ('Ada', 42), ('Grace', 37), ('Linus', 25)
)
SELECT name, points,
       RANK() OVER (ORDER BY points DESC) AS position
FROM scores
WHERE points >= 30
ORDER BY position;
```

## HTML

```html
<!doctype html>
<html lang="en">
  <head><title>Greeting</title></head>
  <body>
    <main class="greeting" data-count="2">
      <h1>Hello, world!</h1>
      <p>A <strong>small</strong> HTML example.</p>
    </main>
  </body>
</html>
```

## CSS

```css
:root {
  --accent: #3366cc;
}

.greeting > h1 {
  color: var(--accent);
  font-size: clamp(1.5rem, 3vw, 2.5rem);
}

@media (prefers-color-scheme: dark) {
  :root { --accent: #88aaff; }
}
```

## JSON

```json
{
  "name": "MarkdownBrowser",
  "native": true,
  "version": 1,
  "languages": ["Swift", "Rust", "TypeScript"],
  "optional": null
}
```

## YAML

```yaml
application:
  name: MarkdownBrowser
  native: true
  languages:
    - Swift
    - Rust
  message: |
    Hello, world!
    A multiline value.
```

## TOML

```toml
[application]
name = "MarkdownBrowser"
native = true
languages = ["Swift", "Rust"]

[editor]
font_size = 14
theme = "system"
```

## XML

```xml
<?xml version="1.0" encoding="UTF-8"?>
<greetings language="en">
  <greeting id="1">Hello, world!</greeting>
  <greeting id="2">Hello, XML &amp; friends!</greeting>
</greetings>
```

## INI

```ini
[application]
name = MarkdownBrowser
native = true

[editor]
font_size = 14
theme = system
```

## Dockerfile

```dockerfile
FROM busybox:1.37
WORKDIR /app
COPY greeting.txt .
ENV GREETING_NAME=world
CMD ["cat", "greeting.txt"]
```

## Makefile

The recipe below starts with a tab, as required by Make.

```makefile
NAME ?= world

.PHONY: greet
greet:
	printf 'Hello, %s!\n' "$(NAME)"
```

## Diff

```diff
--- a/greeting.txt
+++ b/greeting.txt
@@ -1,2 +1,2 @@
-Hello, reader!
+Hello, world!
 Welcome to MarkdownBrowser.
```

## Markdown

````markdown
# A small document

Some **bold**, *italic*, and `inline code`.

- [x] Add an example
- [ ] Try the other theme

```swift
print("A nested code fence")
```
````

## Plain text

An explicit plain-text language tag should not add token colors.

```text
Hello, world!
const count = 42;
This is deliberately plain text.
```

## Untagged code

Without a language tag, code stays plain text. Languages are not auto-detected.

```
struct Greeting {
    let name = "world"
}
```

## Unsupported language

An unknown language tag also falls back to plain text.

```not-a-real-language
function greet(name) {
  return "Hello, " + name;
}
```
