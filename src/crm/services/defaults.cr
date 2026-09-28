# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Valeurs initiales de la relation client (ADR-009 D3) : étapes du
  # pipeline, motifs de perte, origines. La migration 0001 les pose à
  # l'installation ; `ensure!` les remet dans une table vide (instance
  # provisionnée avec l'extension active, specs qui vident les tables entre
  # les exemples). Les libellés sont traduits tant que le dossier ne les a
  # pas renommés (`name` vide). Interne.
  module Defaults
    # Code, ordre, probabilité, genre.
    STAGES = [
      {"discovery", 10, 10, "open"},
      {"qualification", 20, 25, "open"},
      {"proposal", 30, 50, "open"},
      {"negotiation", 40, 75, "open"},
      {"won", 1000, 100, "won"},
      {"lost", 1010, 0, "lost"},
    ]

    LOSS_REASONS = %w[price competitor no_budget no_decision timing other]

    SOURCES = %w[fair website referral prospecting network other]

    def self.ensure! : Nil
      unless Stage.all.exists?
        STAGES.each do |(code, position, probability, kind)|
          Stage.create!(code: code, name: "", position: position, probability: probability, kind: kind, active: true)
        end
      end
      unless LossReason.all.exists?
        LOSS_REASONS.each_with_index(1) { |code, index| LossReason.create!(code: code, name: "", position: index * 10, active: true) }
      end
      unless Source.all.exists?
        SOURCES.each_with_index(1) { |code, index| Source.create!(code: code, name: "", position: index * 10, active: true) }
      end
    end
  end
end

# Instance provisionnée avec l'extension active (convention C6 du cœur).
Partiduo::Api::InitialData.register("CRM", "defaults", order: 100) do |_context|
  Crm::Defaults.ensure!
end
