# workflows/

每个**业务场景**一个**子目录**，子目录内放 `README.md` 加配套脚本 / 数据 / 私有 SOP。

新任务来时：
1. 先读本目录 `index.md`（如果有）—— 只读这一张表，命中就按现成模板走
2. 不命中再设计新流程；任务结束后必须沉淀回这里（见 `../SKILL.md` Step 0 / Step 6）

## 子目录结构

```
workflows/
├── index.md              # 索引：场景 slug | 触发短语 | 关键产物 (查历史只查这张表)
├── <scenario-A>/
│   ├── README.md
│   ├── <script>.py
│   └── <data>.json
├── <scenario-B>/
│   └── README.md
└── ...
```

## README.md 模板（每个场景子目录必含）

```markdown
# <一句话场景标题>

## 场景
触发短语 / 输入 / 现象。具体（域名、按钮文字、错误码）。

## 关键参数（pin）
| 项 | 值 |
|---|---|
| URL / ID / 客服 / 限额 | ... |
（永远不要让用户再口报一次）

## 适用范围
✅ 哪些情况用 / ❌ 哪些情况不要用

## 关键决策点
| 决策 | 判据 | 走哪边 |

## 步骤
| # | 动作 | 用什么工具 | 实现什么目的 | 易踩坑 |

## 输出物
落到哪 / 标准输出。

## 易踩坑（合集）
- ❌ ...

## changelog
- YYYY-MM-DD · 首版 · 来源
```

## 跟 references/recipes.md 的区别

- `references/recipes.md` = playwright **代码片段** cookbook（10 个通用 primitive：连接、抓页、拦 XHR、截图、stealth、async 等）
- `workflows/<scenario>/` = **业务场景**模板（场景 / 决策点 / 步骤 / 易踩坑），用 recipes 的片段作为零件

workflow 描述「为什么这么做 + 顺序」，recipes 描述「怎么写一段能跑的代码」。

## 公版 fork 默认空

公版 fork 这个目录默认不放业务 workflow（绝大多数业务场景含个人 / 公司隐私）。用户自己用时按 SKILL.md Step 6 累积自己的 workflow 库。
