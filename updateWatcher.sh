#!/bin/bash

# Set your project id from Blockfrost
PROJECT_ID="enter your project id here"

# Get the latest ERGO block
latest_ergo_block=$(curl -s "https://api.ergoplatform.com/api/v1/blocks?limit=1" | jq '.items[0].height')

# Get the latest Cardano block
latest_block=$(curl -s -H "project_id: $PROJECT_ID" "https://cardano-mainnet.blockfrost.io/api/v0/blocks/latest")

# Extract the Cardano block number, slot and hash
block_number=$(echo $latest_block | jq -r '.height')
absolute_slot_number=$(echo $latest_block | jq -r '.slot')
transaction_hash=$(echo $latest_block | jq -r '.hash')

# Show the values to the user and ask for confirmation
echo ""
echo "The following values will be written to the local.yaml file:"
echo "Make sure you see 4 good values below before accepting:"
echo "   ERGO block: $latest_ergo_block"
echo "   Cardano block number: $block_number"
echo "   Cardano slot: $absolute_slot_number"
echo "   Cardano transaction hash: $transaction_hash"
echo ""
echo "Do you want to update these values (u), keep the current values (k), or cancel the entire script (c)?"
read -r confirmation
confirmation=$(echo "$confirmation" | tr '[:upper:]' '[:lower:]')  # convert to lowercase

if [ "$confirmation" == "u" ]; then
    # Replace the values in the local.yaml file
    sed -i "s/initialHeight: .*/initialHeight: $latest_ergo_block/" config/local.yaml
    sed -i "s/height: .*/height: $block_number/" config/local.yaml
    sed -i "s/hash: .*/hash: $transaction_hash/" config/local.yaml
    sed -i "s/slot: .*/slot: $absolute_slot_number/" config/local.yaml
    if [ $? -eq 0 ]; then
        echo -e "\nChanges successfully made to the local.yaml file."
    else
        echo "Failed to make changes to the local.yaml file. Exiting."
        exit 1
    fi
elif [ "$confirmation" == "k" ]; then
    echo "Keeping current values. Skipping update."
elif [ "$confirmation" == "c" ]; then
    echo "Operation cancelled by the user. Exiting."
    exit 1
else
    echo "Invalid option. Please enter 'u' to update, 'k' to keep current values, or 'c' to cancel."
    exit 1
fi

# Continue with the rest of the script...

# # Check if the local.yaml.gpg file exists
# if [ -f "config/local.yaml.gpg" ]; then
#     # Decrypt the local.yaml file
#     echo ""
#     echo "Enter decryption password:"
#     read -s decrypt_password
#     gpg --batch --yes --passphrase "${decrypt_password}" --output config/local.yaml --decrypt config/local.yaml.gpg
#     if [ $? -eq 0 ]; then
#         echo "Decryption successful. You now have an unencrypted local.yaml file. It will be re-encrypted after the changes are made."
#     else
#         echo "Decryption failed. Exiting."
#         exit 1
#     fi
# else
#     echo "No existing local.yaml.gpg file found. Skipping decryption."
# fi

# Ask the user for the next action
while true; do
    echo "What do you want to do next? It will happen as soon as you enter the option with no confirmation."
    echo "Press U or u to update Docker image. (docker compose pull, down, then up -d)"
    echo "Press R or r to pull tip and restart Watcher. (docker compose up -d)"
    echo "Press D or d to remove Postgres database. (docker compose down, then volume remove, then up -d)"
    echo "Press S or s to shut down and restart. (docker compose down, then docker compose up -d)"
    echo "Press C or c to cancel."
    read -r next_action
    next_action=$(echo "$next_action" | tr '[:upper:]' '[:lower:]')  # convert to lowercase

    case "$next_action" in
        u)
            echo "Updating Docker image..."
            sudo docker compose pull
            sudo docker compose down
            sudo docker compose up -d
            break
            ;;
        r)
            echo "Pulling tip and restarting Watcher..."
            sudo docker compose up -d
            break
            ;;
        d)
            echo "Removing Postgres database..."
            sudo docker compose down
            sudo docker volume remove watcher_postgres_data
            sudo docker compose up -d
            break
            ;;
        s)
            echo "Shutting down and restarting..."
            sudo docker compose down
            sudo docker compose up -d
            break
            ;;
        c)
            echo "Operation cancelled by the user. Exiting."
            break
            ;;
        *)
            echo "Invalid option. Please enter U/u, R/r, D/d, S/s, or C/c."
            ;;
    esac
done

# echo ""
# echo "The local.yaml file will now be re-encrypted."

# # Encrypt the local.yaml file
# while true; do
#     echo "Enter encryption password:"
#     read -s encrypt_password
#     echo "Confirm encryption password:"
#     read -s encrypt_password_confirm
#     if [ "$encrypt_password" == "$encrypt_password_confirm" ]; then
#         break
#     else
#         echo "Passwords do not match. Please try again."
#     fi
# done
# gpg --batch --yes --cipher-algo AES256 --passphrase "${encrypt_password}" --symmetric --output config/local.yaml.gpg config/local.yaml

# # Remove the decrypted local.yaml file
# rm config/local.yaml

# # Inform the user about the successful operations
# echo -e "\nThe local.yaml file was successfully updated and encrypted."



echo "Operation completed successfully."