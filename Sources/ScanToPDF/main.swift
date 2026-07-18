import Foundation

// Point d'entrée. umask 0o007 AVANT tout accès fichier : les fichiers créés dans le dossier PARTAGÉ
// (/Users/Shared/ScanToPDF, /Users/Shared/FVJC_SCAN) sont alors lisibles/inscriptibles par le groupe
// staff → accessibles aux autres comptes du Mac (même logique qu'ArchivesSearch).
umask(0o007)

ScanToPDFApp.main()
