import { always } from "@antithesishq/bombadil";
import { CharSet } from "@antithesishq/bombadil/actions";
import {
  actions,
  Attributes,
  extract,
  weighted,
} from "@antithesishq/bombadil/terminal";
import { typeFromSet } from "@antithesishq/bombadil/terminal/defaults/actions";
export { noReplacementChars } from "@antithesishq/bombadil/terminal/defaults/properties";

const startMarker = "BOMBADIL_START";
const endMarker = "BOMBADIL_END";

const terminal = extract((state) => {
  const lines: string[] = [];
  let startVisible = false;
  let startBold = true;
  let scrollbarThumbRows = 0;
  let scrollbarRailRows = 0;

  for (let row = 0; row < state.grid.size.rows; row++) {
    const text = state.grid.rowText(row);
    lines.push(text);
    if (text.endsWith("█")) scrollbarThumbRows++;
    if (text.endsWith("│")) scrollbarRailRows++;

    const start = text.indexOf(startMarker);
    if (start < 0) continue;

    startVisible = true;
    const cells = state.grid.row(row);
    for (let column = start; column < start + startMarker.length; column++) {
      if (!Attributes.has(cells[column].style, Attributes.Bold)) {
        startBold = false;
      }
    }
  }

  return {
    lines,
    bottomLine: lines.length > 0 ? lines[lines.length - 1] : "",
    startVisible,
    startBold,
    scrollbarThumbRows,
    scrollbarRailRows,
    exitStatus: state.exitStatus,
    lastAction: state.lastAction,
  };
});

function lastInputIs(...inputs: string[]): boolean {
  const action = terminal.current.lastAction;
  return action !== null && "TypeText" in action && inputs.includes(action.TypeText);
}

function markerVisible(marker: string): boolean {
  return terminal.current.lines.some((line) => line.includes(marker));
}

function searchOpen(): boolean {
  return terminal.current.lines.slice(-2).some((line) => line.startsWith("/"));
}

export const remainsRunning = always(() => terminal.current.exitStatus === null);

export const rendersDocument = always(() =>
  terminal.current.lines.some((line) => line.trim() !== ""),
);

export const homeShowsStart = always(() =>
  !lastInputIs("g", "\x1b[H") || searchOpen() || markerVisible(startMarker),
);

export const endShowsEnd = always(() =>
  !lastInputIs("G", "\x1b[F") || searchOpen() || markerVisible(endMarker),
);

export const startHeadingIsBold = always(() =>
  !terminal.current.startVisible || terminal.current.startBold,
);

export const scrollbarFitsLongDocument = always(() =>
  terminal.current.scrollbarRailRows === 0 ||
  terminal.current.scrollbarThumbRows <= terminal.current.scrollbarRailRows,
);

export const loneTagsNeverRender = always(() =>
  !terminal.current.lines.some((line) =>
    line.includes("BOMBADIL_BADGE") || line.includes("data-bombadil"),
  ),
);

export const searchBarAppearsAfterSlash = always(() =>
  !lastInputIs("/") || terminal.current.bottomLine.startsWith("/"),
);

export const escapeClearsSearchBar = always(() =>
  !lastInputIs("\x1b") || !terminal.current.bottomLine.startsWith("/"),
);

const navigation = typeFromSet(CharSet.fromLiterals(
  "j",
  "k",
  "f",
  "b",
  "g",
  "G",
  " ",
  "\x02",
  "\x04",
  "\x06",
  "\x15",
  "\x0c",
  "\x1b[A",
  "\x1b[B",
  "\x1b[H",
  "\x1b[F",
  "\x1b[5~",
  "\x1b[6~",
));

const batchedNavigation = typeFromSet(CharSet.fromLiterals(
  "jjjjjj",
  "kkkkkk",
  "gG",
  "Gg",
  "\x1b[B\x1b[B\x1b[B",
  "\x1b[A\x1b[A\x1b[A",
  "\x1b[6~\x1b[6~",
  "\x1b[5~\x1b[5~",
));

const ignoredUnicode = typeFromSet(CharSet.union(
  CharSet.fromRange(0x0370, 0x03ff),
  CharSet.fromRange(0x0400, 0x04ff),
  CharSet.fromRange(0x1f600, 0x1f64f),
));

const searchInput = typeFromSet(CharSet.fromLiterals(
  "/",
  "a",
  "e",
  "i",
  "o",
  "n",
  "N",
  "s",
  "t",
  "\x1b",
  "\x0d",
  "\x7f",
  "\x08",
));

export const input = weighted([
  [40, navigation],
  [5, batchedNavigation],
  [10, ignoredUnicode],
  [6, searchInput],
  [2, actions(() => [{ Resize: { columns: [20, 120], rows: [5, 40] } }])],
]);
