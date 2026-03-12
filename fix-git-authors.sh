#!/usr/bin/env bash
set -euo pipefail

OLD_EMAIL="shobhit@Shobhits-MacBook-Air-2.local"
NEW_NAME="shobhit99"
NEW_EMAIL="shobhitbhosure7@gmail.com"

git filter-branch --force --env-filter "
  if [ \"\$GIT_AUTHOR_EMAIL\" = \"$OLD_EMAIL\" ]; then
    export GIT_AUTHOR_NAME=\"$NEW_NAME\"
    export GIT_AUTHOR_EMAIL=\"$NEW_EMAIL\"
  fi
  if [ \"\$GIT_COMMITTER_EMAIL\" = \"$OLD_EMAIL\" ]; then
    export GIT_COMMITTER_NAME=\"$NEW_NAME\"
    export GIT_COMMITTER_EMAIL=\"$NEW_EMAIL\"
  fi
" --tag-name-filter cat -- --branches --tags

echo ""
echo "Done. Verify with: git log --format='%an <%ae>' | sort | uniq -c"
echo ""
echo "Then force-push all branches:"
echo "  git push --force --all origin"
