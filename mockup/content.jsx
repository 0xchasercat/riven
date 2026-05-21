// Static content for Riven mockups: file tree, code samples (Swift + Rust),
// terminal sessions. Pre-tokenized with class names that map to theme.sx.

// ─── File tree ───────────────────────────────────────────────
const FILE_TREE = [
  { kind: 'group', label: 'RIVEN', expanded: true, children: [
    { kind: 'dir', name: 'Sources', expanded: true, children: [
      { kind: 'dir', name: 'Amber', expanded: true, children: [
        { kind: 'file', name: 'RivenApp.swift' },
        { kind: 'file', name: 'AppDelegate.swift' },
        { kind: 'file', name: 'PaneView.swift', active: true, dirty: true },
        { kind: 'file', name: 'WindowController.swift' },
        { kind: 'dir', name: 'Panes', expanded: true, children: [
          { kind: 'file', name: 'GhosttyView.swift' },
          { kind: 'file', name: 'STTextViewPane.swift' },
          { kind: 'file', name: 'PaneGrid.swift' },
        ]},
        { kind: 'dir', name: 'Session', expanded: false, children: [] },
        { kind: 'dir', name: 'Search', expanded: false, children: [] },
      ]},
    ]},
    { kind: 'dir', name: 'crates', expanded: true, children: [
      { kind: 'dir', name: 'riven-core', expanded: true, children: [
        { kind: 'dir', name: 'src', expanded: true, children: [
          { kind: 'file', name: 'lib.rs' },
          { kind: 'file', name: 'registry.rs', active: true, dirty: true },
          { kind: 'file', name: 'split.rs', dirty: true },
        ]},
        { kind: 'file', name: 'Cargo.toml' },
      ]},
      { kind: 'dir', name: 'riven-search', expanded: false, children: [] },
    ]},
    { kind: 'file', name: 'Package.swift' },
    { kind: 'file', name: 'README.md' },
  ]},
];

// ─── Swift code (active editor) ──────────────────────────────
// Each line is an array of {t: token-class, v: value} segments.
// Token classes: kw, fn, str, num, cm, ty, punc, prop, tag, plain
const SWIFT_CODE = [
  [{ t: 'cm', v: '// PaneView.swift — flips between Ghostty + STTextView' }],
  [],
  [{ t: 'kw', v: 'import' }, { v: ' SwiftUI' }],
  [{ t: 'kw', v: 'import' }, { v: ' STTextView' }],
  [{ t: 'kw', v: 'import' }, { v: ' GhosttyKit' }],
  [],
  [{ t: 'kw', v: 'struct' }, { v: ' ' }, { t: 'ty', v: 'PaneView' }, { t: 'punc', v: ':' }, { v: ' ' }, { t: 'ty', v: 'View' }, { v: ' {' }],
  [{ v: '    @' }, { t: 'kw', v: 'Binding' }, { v: ' ' }, { t: 'kw', v: 'var' }, { v: ' pane' }, { t: 'punc', v: ':' }, { v: ' ' }, { t: 'ty', v: 'Pane' }],
  [{ v: '    @' }, { t: 'kw', v: 'Environment' }, { t: 'punc', v: '(\\.' }, { v: 'paneTheme' }, { t: 'punc', v: ')' }, { v: ' ' }, { t: 'kw', v: 'var' }, { v: ' theme' }],
  [],
  [{ v: '    ' }, { t: 'kw', v: 'var' }, { v: ' body' }, { t: 'punc', v: ':' }, { v: ' ' }, { t: 'kw', v: 'some' }, { v: ' ' }, { t: 'ty', v: 'View' }, { v: ' {' }],
  [{ v: '        ' }, { t: 'ty', v: 'ZStack' }, { v: ' {' }],
  [{ v: '            theme.background.' }, { t: 'fn', v: 'ignoresSafeArea' }, { v: '()' }],
  [],
  [{ v: '            ' }, { t: 'kw', v: 'switch' }, { v: ' pane.kind {' }],
  [{ v: '            ' }, { t: 'kw', v: 'case' }, { t: 'punc', v: ' .' }, { v: 'terminal' }, { t: 'punc', v: '(' }, { t: 'kw', v: 'let' }, { v: ' session' }, { t: 'punc', v: ')' }, { v: ':' }],
  [{ v: '                ' }, { t: 'ty', v: 'GhosttyView' }, { t: 'punc', v: '(' }, { v: 'session' }, { t: 'punc', v: ':' }, { v: ' session' }, { t: 'punc', v: ')' }],
  [{ v: '                    .' }, { t: 'fn', v: 'metalRenderer' }, { v: '(.continuous)' }],
  [],
  [{ v: '            ' }, { t: 'kw', v: 'case' }, { t: 'punc', v: ' .' }, { v: 'editor' }, { t: 'punc', v: '(' }, { t: 'kw', v: 'let' }, { v: ' document' }, { t: 'punc', v: ')' }, { v: ':' }],
  [{ v: '                ' }, { t: 'ty', v: 'STTextViewPane' }, { t: 'punc', v: '(' }, { v: 'document' }, { t: 'punc', v: ':' }, { v: ' document' }, { t: 'punc', v: ')' }],
  [{ v: '                    .' }, { t: 'fn', v: 'syntaxHighlighter' }, { v: '(.treeSitter)' }],
  [{ v: '                    .' }, { t: 'fn', v: 'lineNumbers' }, { v: '(.always)' }],
  [{ v: '            }' }],
  [{ v: '        }' }],
  [{ v: '        .' }, { t: 'fn', v: 'focusedValue' }, { t: 'punc', v: '(\\.' }, { v: 'activePane, pane.id)' }],
  [{ v: '        .' }, { t: 'fn', v: 'onKeyPress' }, { t: 'punc', v: '(' }, { v: '.flip' }, { t: 'punc', v: ')' }, { v: ' { pane.' }, { t: 'fn', v: 'toggleKind' }, { v: '() }' }],
  [{ v: '    }' }],
  [{ v: '}' }],
];

// ─── Rust code (second editor) ──────────────────────────────
const RUST_CODE = [
  [{ t: 'kw', v: 'use' }, { v: ' tokio' }, { t: 'punc', v: '::' }, { v: 'sync' }, { t: 'punc', v: '::' }, { v: 'mpsc;' }],
  [{ t: 'kw', v: 'use' }, { v: ' crate' }, { t: 'punc', v: '::' }, { v: '{' }, { t: 'ty', v: 'Pane' }, { v: ', ' }, { t: 'ty', v: 'PaneId' }, { v: ', ' }, { t: 'ty', v: 'Direction' }, { v: '};' }],
  [],
  [{ t: 'cm', v: '/// Tiling pane registry — backs the AppKit NSSplitView grid.' }],
  [{ t: 'kw', v: 'pub struct' }, { v: ' ' }, { t: 'ty', v: 'PaneRegistry' }, { v: ' {' }],
  [{ v: '    panes' }, { t: 'punc', v: ':' }, { v: ' ' }, { t: 'ty', v: 'HashMap' }, { t: 'punc', v: '<' }, { t: 'ty', v: 'PaneId' }, { t: 'punc', v: ',' }, { v: ' ' }, { t: 'ty', v: 'Pane' }, { t: 'punc', v: '>,' }],
  [{ v: '    active' }, { t: 'punc', v: ':' }, { v: ' ' }, { t: 'ty', v: 'Option' }, { t: 'punc', v: '<' }, { t: 'ty', v: 'PaneId' }, { t: 'punc', v: '>,' }],
  [{ v: '    tx' }, { t: 'punc', v: ':' }, { v: ' mpsc' }, { t: 'punc', v: '::' }, { t: 'ty', v: 'Sender' }, { t: 'punc', v: '<' }, { t: 'ty', v: 'PaneEvent' }, { t: 'punc', v: '>,' }],
  [{ v: '}' }],
  [],
  [{ t: 'kw', v: 'impl' }, { v: ' ' }, { t: 'ty', v: 'PaneRegistry' }, { v: ' {' }],
  [{ v: '    ' }, { t: 'kw', v: 'pub async fn' }, { v: ' ' }, { t: 'fn', v: 'split' }, { v: '(' }, { t: 'punc', v: '&mut' }, { v: ' ' }, { t: 'kw', v: 'self' }, { v: ', id' }, { t: 'punc', v: ':' }, { v: ' ' }, { t: 'ty', v: 'PaneId' }, { v: ', dir' }, { t: 'punc', v: ':' }, { v: ' ' }, { t: 'ty', v: 'Direction' }, { v: ')' }],
  [{ v: '        ' }, { t: 'punc', v: '->' }, { v: ' ' }, { t: 'ty', v: 'Result' }, { t: 'punc', v: '<' }, { t: 'ty', v: 'PaneId' }, { t: 'punc', v: '>' }, { v: ' {' }],
  [{ v: '        ' }, { t: 'kw', v: 'let' }, { v: ' parent ' }, { t: 'punc', v: '=' }, { v: ' ' }, { t: 'kw', v: 'self' }, { v: '.panes.' }, { t: 'fn', v: 'get' }, { v: '(' }, { t: 'punc', v: '&' }, { v: 'id).' }, { t: 'fn', v: 'context' }, { v: '(' }, { t: 'str', v: '"missing parent"' }, { v: ')?;' }],
  [{ v: '        ' }, { t: 'kw', v: 'let' }, { v: ' child_id ' }, { t: 'punc', v: '=' }, { v: ' ' }, { t: 'ty', v: 'PaneId' }, { t: 'punc', v: '::' }, { t: 'fn', v: 'new' }, { v: '();' }],
  [{ v: '        ' }, { t: 'kw', v: 'self' }, { v: '.panes.' }, { t: 'fn', v: 'insert' }, { v: '(child_id, parent.' }, { t: 'fn', v: 'split_inheriting' }, { v: '(dir));' }],
  [{ v: '        ' }, { t: 'kw', v: 'self' }, { v: '.tx.' }, { t: 'fn', v: 'send' }, { v: '(' }, { t: 'ty', v: 'PaneEvent' }, { t: 'punc', v: '::' }, { t: 'ty', v: 'Split' }, { v: ' { parent' }, { t: 'punc', v: ':' }, { v: ' id, child' }, { t: 'punc', v: ':' }, { v: ' child_id, dir }).' }, { t: 'fn', v: 'await' }, { v: '?;' }],
  [{ v: '        ' }, { t: 'ty', v: 'Ok' }, { v: '(child_id)' }],
  [{ v: '    }' }],
  [{ v: '}' }],
];

// ─── Terminal sessions ───────────────────────────────────────
// Each line: {t: term-class, v: text}. Classes: prompt, cmd, ok, warn, err, info, plain
const TERM_CARGO = [
  { t: 'prompt', v: '~/riven ' }, { t: 'cmd', v: '$ cargo run --release' },
  '\n',
  { t: 'info', v: '   Compiling' }, { v: ' riven-core v0.4.2' },
  '\n',
  { t: 'info', v: '   Compiling' }, { v: ' riven-pane v0.4.2' },
  '\n',
  { t: 'info', v: '   Compiling' }, { v: ' riven v0.4.2 ' }, { v: '(/Users/jp/riven)' },
  '\n',
  { t: 'ok', v: '    Finished' }, { v: ' `release` profile [optimized] in 8.24s' },
  '\n',
  { t: 'info', v: '     Running' }, { v: ' `target/release/riven`' },
  '\n\n',
  { v: '[' }, { t: 'info', v: 'INFO ' }, { v: ' riven::session] restoring workspace ' }, { t: 'ok', v: "'riven'" }, { v: ' (4 panes)' },
  '\n',
  { v: '[' }, { t: 'info', v: 'INFO ' }, { v: ' riven::ghostty] libghostty 1.2.0 ready · ' }, { t: 'ok', v: 'metal' },
  '\n',
  { v: '[' }, { t: 'info', v: 'INFO ' }, { v: ' riven::sttextview] TextKit 2 editor ready: ' }, { t: 'ok', v: 'native' },
  '\n',
  { v: '[' }, { t: 'warn', v: 'WARN ' }, { v: ' riven::pane] pane 3 fps drop: 119 → 117' },
  '\n',
  { v: '[' }, { t: 'info', v: 'INFO ' }, { v: ' riven::ipc] socket /tmp/riven.sock listening' },
  '\n',
];

const TERM_TEST = [
  { t: 'prompt', v: '~/riven ' }, { t: 'cmd', v: '$ cargo test -p riven-pane' },
  '\n',
  { t: 'info', v: '    Finished' }, { v: ' `test` profile [unoptimized] in 3.1s' },
  '\n',
  { t: 'info', v: '     Running' }, { v: ' unittests src/lib.rs' },
  '\n\n',
  { v: 'running 14 tests' },
  '\n',
  { v: 'test pane::split_horizontal ......... ' }, { t: 'ok', v: 'ok' },
  '\n',
  { v: 'test pane::split_vertical ........... ' }, { t: 'ok', v: 'ok' },
  '\n',
  { v: 'test pane::flip_term_to_editor ...... ' }, { t: 'ok', v: 'ok' },
  '\n',
  { v: 'test pane::resurrect_layout ......... ' }, { t: 'ok', v: 'ok' },
  '\n',
  { v: 'test pane::focus_neighbour .......... ' }, { t: 'ok', v: 'ok' },
  '\n',
  { v: 'test pane::cwd_inheritance .......... ' }, { t: 'ok', v: 'ok' },
  '\n\n',
  { t: 'ok', v: 'test result: ok.' }, { v: ' 14 passed; 0 failed; ' }, { t: 'info', v: '0.04s' },
  '\n\n',
  { t: 'prompt', v: '~/riven ' }, { t: 'cmd', v: '$ ' }, { t: 'cursor', v: '' },
];

window.RIVEN_CONTENT = { FILE_TREE, SWIFT_CODE, RUST_CODE, TERM_CARGO, TERM_TEST };
