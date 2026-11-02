# Changelog

## 0.1.0 (unreleased)

- GitHub and GitLab backends behind one generic interface (`gh`, `glab`; GitLab via REST).
- Tabbed list of PRs/MRs and issues with state and filter cycling.
- Item pages: description, checks, reviewers, conversation cards.
- Diff review buffer with threads in place, pending inline comments saved to disk,
  and one submitted review (comment, approve, request changes).
- Create PR/MR (pre-filled, pushes the branch if needed) and issues; comment, reply,
  merge, close and reopen.
- Auth status, login and logout for both platforms, including self-hosted hosts.
- Magit: `@` in `magit-dispatch`, optional status section.
- Server error reasons are shown, not just the HTTP status.
- Suggested changes (`s` in the diff buffer), rendered as a green "Suggested change" block.
- Commits: listed on the PR page; one commit's diff, read-only; walk with `)` and `(`.
- Closed lists include merged PRs; lists are paged with `>` (load more).
- Diff buffer in sections (overview, files index, threads index, changes, outdated)
  with file banners, tinted comment cards, and `RET` / `}` `{` navigation.
- `@` completes user names while writing a comment: participants first, then the
  repo's assignable users/members; mentions are highlighted when rendered.
- Post one inline comment immediately, without a review: `C-c C-p` in the comment
  buffer, or `P` on a pending comment.
- Fixed: colors lost to font-lock; diff text echoed instead of shown.
