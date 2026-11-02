/** Heading anchors compatible with github-slugger, including `-1`, `-2` suffixes for duplicates. */
export class Slugger {
  private occurrences = new Map<string, number>()

  slug(text: string): string {
    const base = githubSlug(text)
    let result = base
    while (this.occurrences.has(result)) {
      const count = this.occurrences.get(base)! + 1
      this.occurrences.set(base, count)
      result = `${base}-${count}`
    }
    this.occurrences.set(result, 0)
    return result
  }
}

export function githubSlug(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, "")
    .replace(/ /g, "-")
}

/** Approximates the rendered text of a heading's markdown source. */
export function headingPlainText(source: string): string {
  return source
    .replace(/^\s{0,3}#{1,6}(\s+|$)/, "")
    .replace(/\s+#+\s*$/, "")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/!?\[([^\]]*)\]\[[^\]]*\]/g, "$1")
    .replace(/<[^>]+>/g, "")
    .replace(/[*_~`]/g, "")
    .trim()
}
