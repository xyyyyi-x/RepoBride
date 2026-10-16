"""回归测试：模型把内部工具调用标记泄漏进正文时的处理。

背景：`_final_from_observations` 用的是未绑定工具的 `self.model`。模型如果仍想继续
调用工具，发不出结构化 tool_call，就会退化成输出内部 DSML 语法
（形如 "<｜｜DSML｜｜tool_calls>"，竖线是全角 U+FF5C），直接漏进用户可见的回答。

修复分三层：system prompt 声明本轮无工具、`_strip_tool_call_markup` 正则剥离、
`_final_from_observations` 检测到标记就退回观察结果兜底。
"""

import pytest
from langchain_core.messages import AIMessage

from app.services.agents.chat_agent import (
    ChatAgent,
    _contains_tool_call_markup,
    _strip_tool_call_markup,
)

FULLWIDTH_PIPE = "｜"


def _dsml_block(preamble: str = "") -> str:
    pipe = FULLWIDTH_PIPE
    return (
        f"{preamble}"
        f"<{pipe}{pipe}DSML{pipe}{pipe}tool_calls>\n"
        f'<{pipe}{pipe}DSML{pipe}{pipe}invoke name="workspace.read_file">\n'
        f'<{pipe}{pipe}DSML{pipe}{pipe}parameter name="path" string="true">config.py</{pipe}{pipe}DSML{pipe}{pipe}parameter>\n'
        f"</{pipe}{pipe}DSML{pipe}{pipe}invoke>\n"
        f"</{pipe}{pipe}DSML{pipe}{pipe}tool_calls>"
    )


def test_detects_fullwidth_dsml_block() -> None:
    assert _contains_tool_call_markup(_dsml_block())


def test_detects_halfwidth_dsml_block() -> None:
    assert _contains_tool_call_markup("<||DSML||tool_calls>call</||DSML||tool_calls>")


def test_detects_truncated_marker() -> None:
    """流式截断时可能只有开头的标记，没有闭合标签。"""
    assert _contains_tool_call_markup(f'前言\n\n<{FULLWIDTH_PIPE}{FULLWIDTH_PIPE}DSML{FULLWIDTH_PIPE}{FULLWIDTH_PIPE}invoke name="x">')


def test_plain_mention_of_dsml_is_not_markup() -> None:
    """正文里讨论 DSML 这个名词本身，不能误判成泄漏。"""
    assert not _contains_tool_call_markup("DSML 是一种标记语法，本文讨论它的设计。")
    assert not _contains_tool_call_markup("正常回答，含 <代码标签> 和 | 表格 |")


def test_strips_block_and_keeps_preamble() -> None:
    assert _strip_tool_call_markup(_dsml_block(preamble="我来查看相关代码。\n\n")) == "我来查看相关代码。"


def test_strips_truncated_marker() -> None:
    truncated = f'前言\n\n<{FULLWIDTH_PIPE}{FULLWIDTH_PIPE}DSML{FULLWIDTH_PIPE}{FULLWIDTH_PIPE}invoke name="x">'
    assert _strip_tool_call_markup(truncated) == "前言"


def test_leaves_normal_markdown_untouched() -> None:
    normal = "## 标题\n\n正常回答，含 | 表格 | 和 <代码标签>。"
    assert _strip_tool_call_markup(normal) == normal


def test_message_content_strips_markup() -> None:
    """修复的接线点：_message_content 必须剥掉标记。"""
    agent = ChatAgent(model=_StubModel())  # type: ignore[arg-type]

    assert "DSML" not in agent._message_content(AIMessage(content=_dsml_block(preamble="前言")))
    # 原始内容仍可取得，供上层判断这轮回答是否有效
    assert "DSML" in agent._raw_message_content(AIMessage(content=_dsml_block(preamble="前言")))
    # list 形式的 content 同样要处理
    assert "DSML" not in agent._message_content(
        AIMessage(content=[{"type": "text", "text": _dsml_block(preamble="前言")}])
    )


def _final_answer_state() -> dict[str, object]:
    return {
        "message": "这个仓库的 RAG 是怎么实现的？",
        "context": {},
        "observations": [
            {"tool_name": "workspace.read_file", "answer": "config.py 使用 pydantic Settings 读取环境变量。"}
        ],
        "tool_calls": [],
        "agent_events": [],
        "prompt_diagnostics": [],
        "model_usage": [],
    }


@pytest.mark.asyncio
async def test_final_answer_returns_clean_model_output() -> None:
    """对照用例：模型给出干净答案时必须原样返回，证明上一条不是因为异常才兜底的。"""
    agent = ChatAgent(model=_StubModel(content="这是正常的最终回答。"))  # type: ignore[arg-type]

    assert await agent._final_from_observations(_final_answer_state()) == "这是正常的最终回答。"  # type: ignore[arg-type]


@pytest.mark.asyncio
async def test_final_answer_falls_back_when_model_emits_markup() -> None:
    """模型在最终回答里吐标记时，应退回观察结果兜底，而不是把标记交给用户。"""
    agent = ChatAgent(model=_StubModel(content=_dsml_block(preamble="我来查看相关代码。\n\n")))  # type: ignore[arg-type]

    answer = await agent._final_from_observations(_final_answer_state())  # type: ignore[arg-type]

    assert "DSML" not in answer
    assert answer


class _StubModel:
    """只实现测试用到的最小接口，不触网。"""

    def __init__(self, content: str = "") -> None:
        self.content = content
        self.messages: list[object] = []

    def bind_tools(self, tools: list[object]) -> "_StubModel":
        return self

    async def ainvoke(self, messages: list[object]) -> AIMessage:
        self.messages = messages
        return AIMessage(content=self.content)
