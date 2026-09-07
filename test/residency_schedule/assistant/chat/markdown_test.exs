defmodule ResidencySchedule.Assistant.Chat.MarkdownTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.Markdown

  doctest Markdown

  defp html(text), do: text |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  describe "blocks" do
    test "blank lines separate paragraphs and single newlines become breaks" do
      assert html("one\ntwo\n\nthree") == "<p>one<br>two</p><p>three</p>"
    end

    test "empty input renders nothing" do
      assert html("") == ""
      assert html("\n\n  \n") == ""
    end

    test "accepts Windows line endings" do
      assert html("a\r\n\r\nb") == "<p>a</p><p>b</p>"
    end

    test "bullets with - or * form one list" do
      assert html("- a\n* b") == "<ul><li>a</li><li>b</li></ul>"
    end

    test "numbered items with . or ) form one list" do
      assert html("1. a\n2) b") == "<ol><li>a</li><li>b</li></ol>"
    end

    test "indented items still count" do
      assert html("  - a\n   1. b") == "<ul><li>a</li></ul><ol><li>b</li></ol>"
    end

    test "a list directly after a paragraph starts a new block" do
      assert html("Today:\n- Clare") == "<p>Today:</p><ul><li>Clare</li></ul>"
    end

    test "headings render one per line" do
      assert html("# Big\n## Small\ntext") == "<h4>Big</h4><h4>Small</h4><p>text</p>"
    end

    test "a hash without a space is plain text" do
      assert html("#hashtag") == "<p>#hashtag</p>"
    end

    test "a dash without a space is plain text" do
      assert html("-5 degrees") == "<p>-5 degrees</p>"
    end
  end

  describe "inline" do
    test "bold, italic, and code" do
      assert html("**b** *i* _i2_ `c`") ==
               "<p><strong>b</strong> <em>i</em> <em>i2</em> <code>c</code></p>"
    end

    test "markers inside code are left alone" do
      assert html("`**not bold**`") == "<p><code>**not bold**</code></p>"
    end

    test "underscores inside words are not italics" do
      assert html("strong_ob_day") == "<p>strong_ob_day</p>"
    end

    test "an unmatched marker is literal" do
      assert html("2 * 3 and a_b") == "<p>2 * 3 and a_b</p>"
    end
  end

  describe "escaping" do
    test "raw HTML is escaped inside paragraphs, lists, headings, and code" do
      assert html("<script>x</script>") == "<p>&lt;script&gt;x&lt;/script&gt;</p>"
      assert html("- <b>hi</b>") == "<ul><li>&lt;b&gt;hi&lt;/b&gt;</li></ul>"
      assert html("# <i>t</i>") == "<h4>&lt;i&gt;t&lt;/i&gt;</h4>"
      assert html("`a < b`") == "<p><code>a &lt; b</code></p>"
    end

    test "ampersands and quotes are escaped" do
      assert html("Tom & \"Jerry\"") == "<p>Tom &amp; &quot;Jerry&quot;</p>"
    end

    test "links and images are not rendered as markup" do
      assert html("[x](javascript:alert(1)) ![p](https://evil/pixel)") ==
               "<p>[x](javascript:alert(1)) ![p](https://evil/pixel)</p>"
    end
  end
end
