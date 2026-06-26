defmodule Magus.Drafts.ProseMirrorConverterTest do
  use ExUnit.Case, async: true

  alias Magus.Drafts.ProseMirrorConverter

  describe "from_markdown/1" do
    test "empty string returns default doc" do
      assert {:ok, doc} = ProseMirrorConverter.from_markdown("")
      assert doc == %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
    end

    test "single paragraph" do
      assert {:ok, doc} = ProseMirrorConverter.from_markdown("Hello world")

      assert %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]} =
               doc

      assert [%{"type" => "text", "text" => "Hello world"}] = content
    end

    test "multiple paragraphs" do
      assert {:ok, doc} =
               ProseMirrorConverter.from_markdown("First paragraph\n\nSecond paragraph")

      assert %{"type" => "doc", "content" => [para1, para2]} = doc
      assert %{"type" => "paragraph", "content" => [%{"text" => "First paragraph"}]} = para1
      assert %{"type" => "paragraph", "content" => [%{"text" => "Second paragraph"}]} = para2
    end

    test "headings h1-h3" do
      for {level, prefix} <- [{1, "#"}, {2, "##"}, {3, "###"}] do
        assert {:ok, doc} = ProseMirrorConverter.from_markdown("#{prefix} Heading #{level}")

        assert %{
                 "type" => "doc",
                 "content" => [
                   %{
                     "type" => "heading",
                     "attrs" => %{"level" => ^level},
                     "content" => [%{"type" => "text", "text" => "Heading " <> _}]
                   }
                 ]
               } = doc
      end
    end

    test "bold text" do
      assert {:ok, doc} = ProseMirrorConverter.from_markdown("Hello **bold** world")

      assert %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]} =
               doc

      assert [
               %{"type" => "text", "text" => "Hello "},
               %{"type" => "text", "text" => "bold", "marks" => [%{"type" => "bold"}]},
               %{"type" => "text", "text" => " world"}
             ] = content
    end

    test "italic text" do
      assert {:ok, doc} = ProseMirrorConverter.from_markdown("Hello *italic* world")

      assert %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]} =
               doc

      assert [
               %{"type" => "text", "text" => "Hello "},
               %{"type" => "text", "text" => "italic", "marks" => [%{"type" => "italic"}]},
               %{"type" => "text", "text" => " world"}
             ] = content
    end

    test "nested bold and italic" do
      assert {:ok, doc} = ProseMirrorConverter.from_markdown("**bold *and italic* text**")

      assert %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]} =
               doc

      assert [
               %{"type" => "text", "text" => "bold ", "marks" => [%{"type" => "bold"}]},
               %{
                 "type" => "text",
                 "text" => "and italic",
                 "marks" => [%{"type" => "bold"}, %{"type" => "italic"}]
               },
               %{"type" => "text", "text" => " text", "marks" => [%{"type" => "bold"}]}
             ] = content
    end

    test "strikethrough" do
      assert {:ok, doc} = ProseMirrorConverter.from_markdown("~~deleted~~")

      assert %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]} =
               doc

      assert [%{"type" => "text", "text" => "deleted", "marks" => [%{"type" => "strike"}]}] =
               content
    end

    test "link" do
      assert {:ok, doc} =
               ProseMirrorConverter.from_markdown("[click here](https://example.com)")

      assert %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]} =
               doc

      assert [
               %{
                 "type" => "text",
                 "text" => "click here",
                 "marks" => [%{"type" => "link", "attrs" => %{"href" => "https://example.com"}}]
               }
             ] = content
    end

    test "inline code" do
      assert {:ok, doc} = ProseMirrorConverter.from_markdown("Use `mix test` to run")

      assert %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]} =
               doc

      assert [
               %{"type" => "text", "text" => "Use "},
               %{"type" => "text", "text" => "mix test", "marks" => [%{"type" => "code"}]},
               %{"type" => "text", "text" => " to run"}
             ] = content
    end

    test "code block with language" do
      md = "```elixir\nIO.puts(\"hello\")\n```"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "codeBlock",
                   "attrs" => %{"language" => "elixir"},
                   "content" => [%{"type" => "text", "text" => "IO.puts(\"hello\")"}]
                 }
               ]
             } = doc
    end

    test "code block without language" do
      md = "```\nsome code\n```"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "codeBlock",
                   "content" => [%{"type" => "text", "text" => "some code"}]
                 }
               ]
             } = doc
    end

    test "bullet list" do
      md = "- item 1\n- item 2\n- item 3"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{"type" => "doc", "content" => [%{"type" => "bulletList", "content" => items}]} =
               doc

      assert length(items) == 3
      assert Enum.all?(items, &(&1["type"] == "listItem"))
    end

    test "ordered list" do
      md = "1. first\n2. second\n3. third"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{"type" => "doc", "content" => [%{"type" => "orderedList", "content" => items}]} =
               doc

      assert length(items) == 3
    end

    test "blockquote" do
      md = "> This is a quote"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "blockquote",
                   "content" => [
                     %{"type" => "paragraph", "content" => [%{"text" => "This is a quote"}]}
                   ]
                 }
               ]
             } = doc
    end

    test "horizontal rule" do
      md = "Before\n\n---\n\nAfter"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{"type" => "doc", "content" => [_, %{"type" => "horizontalRule"}, _]} = doc
    end

    test "table with header" do
      md = "| Col A | Col B |\n|-------|-------|\n| cell1 | cell2 |"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{"type" => "doc", "content" => [%{"type" => "table", "content" => rows}]} = doc
      assert [header_row, data_row] = rows

      assert %{"type" => "tableRow", "content" => header_cells} = header_row
      assert Enum.all?(header_cells, &(&1["type"] == "tableHeader"))

      assert %{"type" => "tableRow", "content" => data_cells} = data_row
      assert Enum.all?(data_cells, &(&1["type"] == "tableCell"))
    end

    test "task list" do
      md = "- [x] done\n- [ ] pending"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{"type" => "doc", "content" => [%{"type" => "taskList", "content" => items}]} =
               doc

      assert [
               %{"type" => "taskItem", "attrs" => %{"checked" => true}},
               %{"type" => "taskItem", "attrs" => %{"checked" => false}}
             ] = items
    end

    test "image" do
      md = "![alt text](https://example.com/img.png)"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => content}]} =
               doc

      assert [
               %{
                 "type" => "image",
                 "attrs" => %{"src" => "https://example.com/img.png", "alt" => "alt text"}
               }
             ] = content
    end

    test "bold within heading" do
      md = "## Hello **bold** heading"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)

      assert %{
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "heading",
                   "attrs" => %{"level" => 2},
                   "content" => [
                     %{"type" => "text", "text" => "Hello "},
                     %{"type" => "text", "text" => "bold", "marks" => [%{"type" => "bold"}]},
                     %{"type" => "text", "text" => " heading"}
                   ]
                 }
               ]
             } = doc
    end

    test "complex document" do
      md = """
      # Title

      A paragraph with **bold** and *italic* text.

      - item 1
      - item 2

      ```elixir
      IO.puts("hello")
      ```

      ---

      > A quote
      """

      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert %{"type" => "doc", "content" => content} = doc
      types = Enum.map(content, & &1["type"])

      assert "heading" in types
      assert "paragraph" in types
      assert "bulletList" in types
      assert "codeBlock" in types
      assert "horizontalRule" in types
      assert "blockquote" in types
    end
  end

  describe "to_markdown/1" do
    test "empty doc" do
      assert "" == ProseMirrorConverter.to_markdown(ProseMirrorConverter.default_doc())
    end

    test "simple paragraph" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello world"}]}
        ]
      }

      assert "Hello world" == ProseMirrorConverter.to_markdown(doc)
    end

    test "heading" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "heading",
            "attrs" => %{"level" => 2},
            "content" => [%{"type" => "text", "text" => "Title"}]
          }
        ]
      }

      assert "## Title" == ProseMirrorConverter.to_markdown(doc)
    end

    test "bold and italic marks" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "normal "},
              %{"type" => "text", "text" => "bold", "marks" => [%{"type" => "bold"}]},
              %{"type" => "text", "text" => " and "},
              %{"type" => "text", "text" => "italic", "marks" => [%{"type" => "italic"}]}
            ]
          }
        ]
      }

      assert "normal **bold** and *italic*" == ProseMirrorConverter.to_markdown(doc)
    end

    test "code block with language" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "codeBlock",
            "attrs" => %{"language" => "elixir"},
            "content" => [%{"type" => "text", "text" => "IO.puts(\"hi\")"}]
          }
        ]
      }

      assert "```elixir\nIO.puts(\"hi\")\n```" == ProseMirrorConverter.to_markdown(doc)
    end

    test "bullet list" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "bulletList",
            "content" => [
              %{
                "type" => "listItem",
                "content" => [
                  %{
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "text" => "item 1"}]
                  }
                ]
              },
              %{
                "type" => "listItem",
                "content" => [
                  %{
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "text" => "item 2"}]
                  }
                ]
              }
            ]
          }
        ]
      }

      assert "- item 1\n- item 2" == ProseMirrorConverter.to_markdown(doc)
    end

    test "link" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "text",
                "text" => "click",
                "marks" => [
                  %{"type" => "link", "attrs" => %{"href" => "https://example.com"}}
                ]
              }
            ]
          }
        ]
      }

      assert "[click](https://example.com)" == ProseMirrorConverter.to_markdown(doc)
    end

    test "blockquote" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "blockquote",
            "content" => [
              %{
                "type" => "paragraph",
                "content" => [%{"type" => "text", "text" => "quoted text"}]
              }
            ]
          }
        ]
      }

      assert "> quoted text" == ProseMirrorConverter.to_markdown(doc)
    end

    test "horizontal rule" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "before"}]},
          %{"type" => "horizontalRule"},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "after"}]}
        ]
      }

      assert "before\n\n---\n\nafter" == ProseMirrorConverter.to_markdown(doc)
    end

    test "table" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "table",
            "content" => [
              %{
                "type" => "tableRow",
                "content" => [
                  %{
                    "type" => "tableHeader",
                    "attrs" => %{"colspan" => 1, "rowspan" => 1},
                    "content" => [
                      %{
                        "type" => "paragraph",
                        "content" => [%{"type" => "text", "text" => "A"}]
                      }
                    ]
                  },
                  %{
                    "type" => "tableHeader",
                    "attrs" => %{"colspan" => 1, "rowspan" => 1},
                    "content" => [
                      %{
                        "type" => "paragraph",
                        "content" => [%{"type" => "text", "text" => "B"}]
                      }
                    ]
                  }
                ]
              },
              %{
                "type" => "tableRow",
                "content" => [
                  %{
                    "type" => "tableCell",
                    "attrs" => %{"colspan" => 1, "rowspan" => 1},
                    "content" => [
                      %{
                        "type" => "paragraph",
                        "content" => [%{"type" => "text", "text" => "1"}]
                      }
                    ]
                  },
                  %{
                    "type" => "tableCell",
                    "attrs" => %{"colspan" => 1, "rowspan" => 1},
                    "content" => [
                      %{
                        "type" => "paragraph",
                        "content" => [%{"type" => "text", "text" => "2"}]
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      expected = "| A | B |\n| --- | --- |\n| 1 | 2 |"
      assert expected == ProseMirrorConverter.to_markdown(doc)
    end
  end

  describe "to_plain_text/1" do
    test "extracts text without formatting" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "heading",
            "attrs" => %{"level" => 1},
            "content" => [%{"type" => "text", "text" => "Title"}]
          },
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "Hello "},
              %{"type" => "text", "text" => "bold", "marks" => [%{"type" => "bold"}]},
              %{"type" => "text", "text" => " world"}
            ]
          }
        ]
      }

      assert "Title\nHello bold world" == ProseMirrorConverter.to_plain_text(doc)
    end

    test "empty doc returns empty string" do
      assert "" == ProseMirrorConverter.to_plain_text(ProseMirrorConverter.default_doc())
    end

    test "code block preserves literal text" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "codeBlock",
            "attrs" => %{"language" => "elixir"},
            "content" => [%{"type" => "text", "text" => "IO.puts(\"hi\")"}]
          }
        ]
      }

      assert "IO.puts(\"hi\")" == ProseMirrorConverter.to_plain_text(doc)
    end

    test "list items on separate lines" do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "bulletList",
            "content" => [
              %{
                "type" => "listItem",
                "content" => [
                  %{
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "text" => "one"}]
                  }
                ]
              },
              %{
                "type" => "listItem",
                "content" => [
                  %{
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "text" => "two"}]
                  }
                ]
              }
            ]
          }
        ]
      }

      assert "one\ntwo" == ProseMirrorConverter.to_plain_text(doc)
    end
  end

  describe "round-trip: markdown → JSON → markdown" do
    test "simple paragraph preserves content" do
      md = "Hello world"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert md == ProseMirrorConverter.to_markdown(doc)
    end

    test "heading preserves content" do
      md = "## My Heading"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert md == ProseMirrorConverter.to_markdown(doc)
    end

    test "bold text preserves content" do
      md = "Hello **bold** world"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert md == ProseMirrorConverter.to_markdown(doc)
    end

    test "code block preserves content" do
      md = "```elixir\nIO.puts(\"hello\")\n```"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert md == ProseMirrorConverter.to_markdown(doc)
    end

    test "bullet list preserves content" do
      md = "- item 1\n- item 2"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert md == ProseMirrorConverter.to_markdown(doc)
    end

    test "blockquote preserves content" do
      md = "> quoted text"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert md == ProseMirrorConverter.to_markdown(doc)
    end

    test "link preserves content" do
      md = "[click](https://example.com)"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert md == ProseMirrorConverter.to_markdown(doc)
    end

    test "strikethrough preserves content" do
      md = "~~deleted~~"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      assert md == ProseMirrorConverter.to_markdown(doc)
    end
  end

  describe "round-trip: markdown → JSON → plain text preserves visible content" do
    test "formatting is stripped but text preserved" do
      md = "# Title\n\nHello **bold** and *italic* [link](url)"
      assert {:ok, doc} = ProseMirrorConverter.from_markdown(md)
      plain = ProseMirrorConverter.to_plain_text(doc)

      assert String.contains?(plain, "Title")
      assert String.contains?(plain, "Hello bold and italic link")
    end
  end
end
