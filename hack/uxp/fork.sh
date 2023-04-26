#!/bin/bash
set -o pipefail

# Set remote repository names
upstream="upstream"
origin="origin"
main_branch="master"

# Stored for later use in help messages
script_call="$0 $@"

# Sync $origin/$branch with $upstream/$branch, rebasing on top of $commit if provided
# If $origin/$branch does not exist, create it using create_new_release function
function sync_branch {
  # Ensure the input is provided
  if [ -z "$1" ]; then
    echo "Error: Missing branch for sync_branch function"
    exit 1
  fi
  local branch=$1

  # Default: No commit or tag provided, use the latest commit from the upstream repository
  local commit=$(git ls-remote $upstream $branch | awk '{print $1}')
  if [ ! -z "$2" ]; then
    # Commit or tag provided
    # Check if the provided commit or tag exists in the upstream repository
    # If it does not exist, it is likely a tag
    # If it exists, it is likely a commit
    # If it is a commit, use it as the base for the rebase
    # If it is a tag, use the commit associated with the tag as the base for the rebase
    # If the provided commit or tag does not exist, error out
    if git ls-remote $upstream $2 | grep -q $2; then
      # Provided commit exists in the upstream repository
      commit=$2
    elif git ls-remote $upstream $2 | grep -q "refs/tags/$2"; then
      # Provided tag exists in the upstream repository
      commit=$(git ls-remote $upstream $2 | awk '{print $1}')
    else
      # Provided commit or tag does not exist in the upstream repository
      echo "Error: Provided commit or tag $2 does not exist in the upstream repository"
      return 1
    fi

    commit=$2
  fi

  # Fetch changes from upstream repository
  git fetch $upstream $branch || return 1

  # Check if the branch exists in the origin repository
  if git show-ref --quiet --verify refs/remotes/$origin/$branch; then
    # Branch exists, sync with upstream
    echo "Updating branch $branch in origin repository..."
    git checkout --track origin/$branch || git checkout $branch || return 1

    git rebase --onto $commit $upstream/$branch || return 1

    # Check if the rebase was successful
    if [ $? -ne 0 ]; then
      # Rebase failed, likely due to conflicts
      echo "Rebase failed for branch $branch in the CI pipeline. Please run the script manually to resolve conflicts and push the changes."
      echo "To resolve conflicts:"
      failure_help_message
      return 1
    fi
    # Rebase succeeded, push changes to the origin repository
    git push $origin $branch --force-with-lease
    if [ $? -ne 0 ]; then
      echo "Push failed for branch $branch in the CI pipeline. This is likely due to missing permissions."
      failure_help_message
      return 1
    fi
  else
    # Branch does not exist, create it using create_new_release function
    echo "Creating branch $branch in origin repository..."
    create_new_release $branch || return 1
  fi

  return 0
}

# Creates a new $origing/$new_release_branch branch from
# $upstream/$new_release_branch. Tries to apply all the UXP specific patches
# from $origin/$main_branch, defined as all the commits on $origin/$main_branch
# from the common ancestor between $origin/$main_branch and
# $upstream/$main_branch
function create_new_release {
  # Ensure the input is provided
  if [ -z "$1" ]; then
    echo "Error: Missing new_release_branch argument for create_new_release function"
    exit 1
  fi

  new_release_branch=$1

  # Fetch changes from upstream and origin repositories
  git fetch $upstream
  git fetch $origin $main_branch

  # Create a new branch for the UXP specific patches
  git checkout -b uxp_specific_patches $origin/$main_branch

  # Find the common ancestor between the master and the upstream master
  common_ancestor=$(git merge-base HEAD $upstream/$main_branch)

  # Create a patch file containing the UXP specific patches
  git format-patch -k --stdout $common_ancestor..HEAD > uxp_specific_patches.patch

  # Checkout the upstream new release branch
  git checkout -b $new_release_branch $upstream/$new_release_branch

  # Apply the UXP specific patches
  git am -3 -k --whitespace=fix uxp_specific_patches.patch

  # Check if the patch application was successful
  if [ $? -ne 0 ]; then
    # Patch application failed, likely due to conflicts
    echo "Patch application failed for branch $new_release_branch in the CI pipeline. Please run the script manually to resolve conflicts and push the changes."
    failure_help_message
    return 1
  else
    # Patch application succeeded, remove the patch file
    rm uxp_specific_patches.patch

    # Push the new release branch to the origin repository
    git push --set-upstream $origin $new_release_branch || return 1
  fi

  # Delete the temporary branch for UXP specific patches
  git branch -D uxp_specific_patches

  echo "New release branch $new_release_branch created and UXP specific patches applied."
}

# Prints a help message for manual resolution of issues
function failure_help_message {
  echo "1. Clone the repository."
  echo "2. Ensure upstream is set to the correct repository: git remote set-url upstream $(git remote -v | grep upstream | awk '{print $2}' | head -n 1)."
  echo "3. Ensure you have the required permissions to solve the issue manually."
  echo "4. Run again \"$script_call\" and solve any issue."
}


# check we are on the specified main branch
if [ "$(git rev-parse --abbrev-ref HEAD)" != "$main_branch" ]; then
  echo "Error: You must be on the $main_branch branch to run this script."
  exit 1
fi

# check upstream remote exists
if ! git remote | grep -q $upstream; then
  echo "Error: Upstream remote $upstream does not exist."
  exit 1
fi

# Check the provided command and call the corresponding function
case "$1" in
  sync_branch)
    sync_branch "${@:2}"
    if [ $? -ne 0 ]; then
      echo "Error creating new release branch. Exiting..."
      exit 1
    fi
    ;;
  *)
    echo "Usage:"
    echo "  $0 sync_branch <release_branch> [commit_or_tag]"
    exit 1
    ;;
esac
