;;; imdb-mode.el --- querying the imdb movie database
;; Copyright (C) 2014 Lars Magne Ingebrigtsen

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: extensions, processes

;; This file is not part of GNU Emacs.

;; imdb.el is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; imdb.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;;; Code:

(require 'imdb)
(require 'sqlite3)

(defvar imdb-db nil)

(defvar imdb-tables
  '((movie
     (mid text :primary)
     (type text)
     (primary-title text)
     (original-title text)
     (adultp bool)
     (start-year integer)
     (end-year integer)
     (length integer))
    (movie-genre
     (mid text :references movie)
     (genre text))
    
    (person
     (pid text :primary)
     (primary-name text)
     (birth-year integer)
     (death-year integer))
    (person-primary-profession
     (pid text :references person)
     (profession text))
    (person-known-for
     (pid text :references person)
     (mid text :references movie))

    (title
     (mid text :references movie)
     (rank integer)
     (title text)
     (region text)
     (language text)
     (types text)
     (attributes text)
     (originalp bool))

    (crew
     (mid text :references movie)
     (pid text :references person)
     (category text))
     
    (episode
     (mid text :primary :references movie)
     (movie text :references movie)
     (season integer)
     (episode integer))

    (rating
     (mid text :primary :references movie)
     (rating real)
     (votes integer))

    (principal
     (mid text :references movie)
     (rank integer)
     (pid text :references person)
     (category text)
     (job text))

    (principal-character
     (mid text :references movie)
     (pid text :references person)
     (character text))    
    ))

(defun imdb-dehyphenate (elem)
  (replace-regexp-in-string "-" "_" (symbol-name elem)))

(defun imdb-hyphenate (elem)
  (replace-regexp-in-string "_" "-" elem))


(defun imdb-download-data ()
  (let ((dom
	 (with-current-buffer (url-retrieve-synchronously "https://datasets.imdbws.com/")
	   (goto-char (point-min))
	   (search-forward "\n\n")
	   (prog1
	       (libxml-parse-html-region (point) (point-max))
	     (kill-buffer (current-buffer))))))
    (loop for elem in (dom-by-tag dom 'a)
	  for url = (dom-attr elem 'href)
	  when (string-match "[.]gz\\'" url)
	  do (imdb-download-data-1 url))))

(defun imdb-download-data-1 (url)
  (with-current-buffer (url-retrieve-synchronously url)
    (goto-char (point-min))
    (search-forward "\n\n")
    (zlib-decompress-region (point) (point-max))
    (let ((file (expand-file-name (replace-regexp-in-string
				   "[.]gz\\'" ""
				   (file-name-nondirectory
				    (url-filename
				     (url-generic-parse-url url))))
				  "~/.emacs.d/imdb")))
      (unless (file-exists-p (file-name-directory file))
	(make-directory (file-name-directory file) t))
      (write-region (point) (point-max) file))
    (kill-buffer (current-buffer))))

(defun imdb-initialize ()
  (unless imdb-db
    (setq imdb-db (sqlite3-new
		   (file-truename "~/.emacs.d/imdb/imdb.sqlite3")))))

(defun imdb-create-tables ()
  (imdb-initialize)
  (loop for (table . columns) in imdb-tables
	do (sqlite3-execute-batch
	    imdb-db (format
		     "create table if not exists %s (%s)"
		     (imdb-dehyphenate table)
		     (mapconcat
		      #'identity
		      (loop for elem in columns
			    collect (format
				     "%s %s%s%s"
				     (imdb-dehyphenate (car elem))
				     (if (equal (cadr elem) 'bool)
					 "text"
				       (cadr elem))
				     (if (memq :primary elem)
					 " primary key"
				       "")
				     (let ((references
					    (cadr (memq :references elem))))
				       (if references
					   (format " references %s"
						   references)
					 ""))))
		      ", "))))

  (sqlite3-execute-batch
   imdb-db "create index if not exists pcidx on principal_character(mid, pid)")
  (sqlite3-execute-batch
   imdb-db "create index if not exists mgidx on movie_genre(mid)")
  (sqlite3-execute-batch
   imdb-db "create index if not exists pppidx on person_primary_profession(pid)")
  (sqlite3-execute-batch
   imdb-db "create index if not exists pkfidx on person_known_for(pid)")
  (sqlite3-execute-batch imdb-db "create index if not exists tidx on title(mid)")
  (sqlite3-execute-batch imdb-db "create index if not exists cidx on crew(mid, pid)")
  (sqlite3-execute-batch imdb-db "create index if not exists eidx on episode(movie)")
  (sqlite3-execute-batch imdb-db "create index if not exists pidx on principal(mid, pid)")
  (sqlite3-execute-batch imdb-db "create index if not exists ppidx on principal(pid)")
  )

(defun imdb-read-line ()
  (loop for elem in (split-string
		     (buffer-substring (point) (line-end-position))
		     "\t")
	collect (if (equal elem "\\N")
		    nil
		  elem)))

(defun imdb-read-data ()
  (with-temp-buffer
    (sqlite3-execute-batch imdb-db "delete from movie")
    (sqlite3-transaction imdb-db)
    (insert-file-contents "~/.emacs.d/imdb/title.basics.tsv")
    (forward-line 1)
    (let ((lines 1)
	  (total (count-lines (point-min) (point-max))))
      (while (not (eobp))
	(when (zerop (% (incf lines) 1000))
	  (message "Read %d lines (%.1f%%)" lines
		   (* (/ (* lines 1.0) total) 100)))
	(let* ((elem (imdb-read-line))
	       (object (imdb-make 'movie elem)))
	  (imdb-insert object)
	  (when (car (last elem))
	    (loop for genre in (split-string (car (last elem)) ",")
		  do (imdb-insert (imdb-make 'movie-genre
					     (list (car elem) genre))))))
	(forward-line 1)))
    (sqlite3-commit imdb-db))

  (with-temp-buffer
    (sqlite3-execute-batch imdb-db "delete from person")
    (sqlite3-transaction imdb-db)
    (insert-file-contents "~/.emacs.d/imdb/name.basics.tsv")
    (forward-line 1)
    (let ((lines 1)
	  (total (count-lines (point-min) (point-max))))
      (while (not (eobp))
	(when (zerop (% (incf lines) 1000))
	  (message "Read %d lines (%.1f%%)" lines
		   (* (/ (* lines 1.0) total) 100)))
	(let* ((elem (imdb-read-line))
	       (object (imdb-make 'person elem)))
	  (imdb-insert object)
	  (let ((professions (car (last elem 2)))
		(known (car (last elem))))
	    (when professions
	      (loop for profession in (split-string professions ",")
		    do (imdb-insert (imdb-make 'person-primary-profession
					       (list (car elem) profession)))))
	    (when known
	      (loop for k in (split-string known ",")
		    do (imdb-insert (imdb-make 'person-known-for
					       (list (car elem) k))))))
	  (forward-line 1)))
      (sqlite3-commit imdb-db)))

  (imdb-read-general 'title "title.akas")
  
  (with-temp-buffer
    (sqlite3-execute-batch imdb-db "delete from crew")
    (sqlite3-transaction imdb-db)
    (insert-file-contents "~/.emacs.d/imdb/title.crew.tsv")
    (forward-line 1)
    (let ((lines 1)
	  (total (count-lines (point-min) (point-max))))
      (while (not (eobp))
	(when (zerop (% (incf lines) 1000))
	  (message "Read %d lines (%.1f%%)" lines
		   (* (/ (* lines 1.0) total) 100)))
	(let* ((elem (imdb-read-line))
	       (directors (cadr elem))
	       (writers (caddr elem)))
	  (when directors
	    (dolist (mid (split-string directors ","))
	      (imdb-insert (imdb-make 'crew (list (car elem) mid "director")))))
	  (when writers
	    (dolist (mid (split-string writers ","))
	      (imdb-insert (imdb-make 'crew (list (car elem) mid "writer")))))
	  (forward-line 1)))
      (sqlite3-commit imdb-db)))

  (imdb-read-general 'episode "title.episode")
  (imdb-read-general 'rating "title.ratings")

  (with-temp-buffer
    (sqlite3-execute-batch imdb-db "delete from principal")
    (sqlite3-transaction imdb-db)
    (insert-file-contents "~/.emacs.d/imdb/title.principals.tsv")
    (forward-line 1)
    (let ((lines 1)
	  (total (count-lines (point-min) (point-max))))
      (while (not (eobp))
	(when (zerop (% (incf lines) 1000))
	  (message "Read %d lines (%.1f%%)" lines
		   (* (/ (* lines 1.0) total) 100)))
	(let* ((elem (imdb-read-line))
	       (object (imdb-make 'principal elem)))
	  (imdb-insert object)
	  (when (car (last elem))
	    (with-temp-buffer
	      (insert (car (last elem)))
	      (goto-char (point-min))
	      (loop for character across (json-read)
		    do (imdb-insert (imdb-make 'principal-character
					       (list (getf object :mid)
						     (getf object :pid)
						     character))))))
	  (forward-line 1)))
      (sqlite3-commit imdb-db))))

(defun imdb-read-general (table file)
  (with-temp-buffer
    (sqlite3-execute-batch imdb-db (format "delete from %s" table))
    (sqlite3-transaction imdb-db)
    (insert-file-contents (format "~/.emacs.d/imdb/%s.tsv" file))
    (forward-line 1)
    (let ((lines 1)
	  (total (count-lines (point-min) (point-max))))
      (while (not (eobp))
	(when (zerop (% (incf lines) 1000))
	  (message "Read %d lines (%.1f%%)" lines
		   (* (/ (* lines 1.0) total) 100)))
	(let* ((elem (imdb-read-line))
	       (object (imdb-make table elem)))
	  (imdb-insert object)
	  (forward-line 1)))
      (sqlite3-commit imdb-db))))

(defun imdb-make (table values)
  (nconc (list :_type table)
	 (loop for column in (cdr (assq table imdb-tables))
	       for value in values
	       for type = (cadr column)
	       append (list (intern (format ":%s" (car column)) obarray)
			    (cond
			     ((and value
				   (or (eq type 'integer)
				       (eq type 'number)
				       (eq type 'float)))
			      (string-to-number value))
			     ((eq type 'bool)
			      (if (equal value "0")
				  "N"
				"Y"))
			     (t
			      value))))))

(defun imdb-exec (statement values)
  ;;(message "%s %S" statement values)
  (sqlite3-execute-batch imdb-db statement values))

(defun imdb-column-name (column)
  (replace-regexp-in-string ":" "" (imdb-dehyphenate column)))

(defvar imdb-db-test nil)

(defun imdb-insert (object)
  (unless imdb-db-test
    (imdb-exec
     (format "insert into %s(%s) values(%s)"
	     (imdb-dehyphenate (getf object :_type))
	     (mapconcat
	      #'identity
	      (loop for (column nil) on (cddr object) by #'cddr
		    collect (imdb-column-name column))
	      ",")
	     (mapconcat
	      #'identity
	      (loop repeat (/ (length (cddr object)) 2)
		    collect "?")
	      ","))
     (coerce
      (loop for (nil value) on (cddr object) by #'cddr
	    collect value)
      'vector))))

(defun imdb-select (table &rest values)
  (apply 'imdb-find table (loop for (key val) on values by #'cddr
				append (list key '= val))))


(defun imdb-select-where (statement &rest values)
  (let ((result nil))
    (sqlite3-execute
     imdb-db
     statement
     (coerce values 'vector)
     (lambda (row names)
       (push (nconc (loop for value in row
			  for column in names
			  append (list
				  (intern (format ":%s" (imdb-hyphenate column))
					  obarray)
				  value)))
	     result)))
    (nreverse result)))

(defun imdb-find (table &rest values)
  (let ((result nil))
    (sqlite3-execute
     imdb-db
     (format
      "select * from %s where %s"
      (imdb-dehyphenate table)
      (mapconcat
       #'identity
       (loop for (column predicate nil) on values by #'cdddr
	     collect (format "%s %s ?"
			     (imdb-column-name column)
			     predicate))
       " and "))
     (coerce
      (loop for (nil nil value) on values by #'cdddr
	    collect value)
      'vector)
     (lambda (row names)
       (message "%S" row)
       (push (nconc (list :_type table)
		    (loop for value in row
			  for column in names
			  append (list
				  (intern (format ":%s" (imdb-hyphenate column))
					  obarray)
				  value)))
	     result)))
    (nreverse result)))

(defvar imdb-mode-map
  (let ((map (make-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "f" 'imdb-mode-search-film)
    (define-key map "p" 'imdb-mode-search-person)
    (define-key map "x" 'imdb-mode-toggle-insignificant)
    (define-key map "\r" 'imdb-mode-select)
    map))

(define-derived-mode imdb-mode special-mode "Imdb"
  "Major mode for examining the imdb database.

\\{imdb-mode-map}"
  (setq buffer-read-only t)
  (buffer-disable-undo)
  (setq-local imdb-mode-filter-insignificant nil)
  (setq-local imdb-mode-mode 'film-search)
  (setq-local imdb-mode-search nil)
  (setq truncate-lines t))

(defun imdb-search (film)
  "Create a buffer to examine the imdb database."
  (interactive "sFilm: ")
  (switch-to-buffer "*imdb*")
  (imdb-initialize)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (imdb-mode)
    (imdb-mode-search-film film)))

(defun imdb-mode-toggle-insignificant ()
  "Toggle whether to list proper films only."
  (interactive)
  (setq imdb-mode-filter-insignificant
	(not imdb-mode-filter-insignificant))
  (message "Unimportant items are now %s"
	   (if imdb-mode-filter-insignificant
	       "filtered"
	     "not filtered"))
  (imdb-mode-refresh-buffer))

(defun imdb-mode-refresh-buffer ()
  (let ((ids (save-excursion
	       (loop repeat 20
		     while (not (eobp))
		     collect (get-text-property (point) 'id)
		     do (forward-line 1)))))
  (cond
   ((eq imdb-mode-mode 'film-search)
    (imdb-mode-search-film imdb-mode-search))
   ((eq imdb-mode-mode 'person)
    (imdb-mode-display-person imdb-mode-search)))
  (if (not ids)
      (goto-char (point-max))
    (loop for id in ids
	  while (not (imdb-mode-goto-id id))))))

(defun imdb-mode-goto-id (id)
  (let ((start (point))
	match)
    (goto-char (point-min))
    (if (setq match (text-property-search-forward 'id id t))
	(progn
	  (goto-char (prop-match-beginning match))
	  (beginning-of-line)
	  t)
      (goto-char start)
      nil)))

(defun imdb-mode-search-film (film)
  "List films matching FILM."
  (interactive "sFilm: ")
  (imdb-initialize)
  (let ((films (imdb-select-where
		"select * from movie where lower(primary_title) like ?"
		(format "%%%s%%" film)))
	(inhibit-read-only t))
    (setq imdb-mode-mode 'film-search
	  imdb-mode-search film)
    (erase-buffer)
    (setq films (imdb-mode-filter films))
    (unless films
      (error "No films match %S" film))
    (dolist (film (cl-sort films '<
			   :key (lambda (e)
				  (or (getf e :start-year)
				      most-positive-fixnum))))
      (insert
       (propertize
	(format "%s %s%s%s\n"
		(propertize (format "%s" (getf film :start-year))
			    'face 'variable-pitch)
		(propertize " " 'display '(space :align-to 8))
		(propertize (getf film :primary-title) 'face 'variable-pitch)
		(if (equal (getf film :type) "movie")
		    ""
		  (propertize (format " (%s)" (getf film :type))
			      'face '(variable-pitch
				      (:foreground "#80a080")))))
	'id (getf film :mid))))
    (goto-char (point-min))))

(defun imdb-mode-search-person (person)
  "List films matching PERSON."
  (interactive "sPerson: ")
  (imdb-initialize)
  (switch-to-buffer (format "*imdb %s*" person))
  (let ((inhibit-read-only t))
    (imdb-mode)
    (setq imdb-mode-mode 'people-search
	  imdb-mode-search person)
    (erase-buffer)
    (imdb-mode-search-person-1 person)))

(defun imdb-mode-search-person-1 (person)
  (let ((people (imdb-select-where
		 "select * from person where lower(primary_name) like ?"
		 (format "%%%s%%" person)))
	(inhibit-read-only t))
    (erase-buffer)
    (unless people
      (error "No people match %S" person))
    (dolist (person (cl-sort people 'string<
			     :key (lambda (e)
				    (getf e :primary-anem))))
      (insert
       (propertize
	(format "%s%s\n"
		(propertize (getf person :primary-name)
			    'face 'variable-pitch)
		(if (not (getf person :birth-year))
		    ""
		  (propertize (format " (%s)" (getf person :birth-year))
			      'face '(variable-pitch
				      (:foreground "#a0a0a0")))))
	'id (getf person :pid))))
    (goto-char (point-min))))

(defun imdb-mode-filter (films)
  (if (not imdb-mode-filter-insignificant)
      films
    (loop for film in films
	  when (and (getf film :start-year)
		    (equal (getf film :type) "movie"))
	  collect film)))

(defun imdb-mode-select ()
  "Select the item under point and display details."
  (interactive)
  (let ((id (get-text-property (point) 'id)))
    (unless id
      (error "Nothing under point"))
    (cond
     ((or (eq imdb-mode-mode 'film-search)
	  (eq imdb-mode-mode 'person))
      (imdb-mode-display-film id))
     (t
      (switch-to-buffer (format "*imdb %s*"
				(getf (car (imdb-select 'person :pid id))
				      :primary-name)))
      (let ((inhibit-read-only t))
	(imdb-mode)
	(imdb-mode-display-person id))))))

(defun imdb-mode-display-film (id)
  (switch-to-buffer (format "*imdb %s*"
			    (getf (car (imdb-select 'movie :mid id))
				  :primary-title)))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (imdb-mode)
    (setq imdb-mode-mode 'film)
    (let ((svg (svg-create 300 400)))
      (svg-gradient svg "background" 'linear '((0 . "#b0b0b0") (100 . "#808080")))
      (svg-rectangle svg 0 0 300 400 :gradient "background"
                     :stroke-width 2 :stroke-color "black")
      (insert-image (svg-image svg)))
    (insert "\n\n")
    (imdb-update-image id)
    (let ((directors
	   (imdb-select-where "select primary_name from person inner join crew on crew.pid = person.pid where crew.category = 'director' and crew.mid = ?"
			      id)))
      (insert
       (if (not directors)
	   ""
	 (concat
	  (propertize "Directed by " 'face 'variable-pitch)
	  (propertize (mapconcat (lambda (e)
				   (getf e :primary-name))
				 directors ", ")
		      'face '(variable-pitch
			      (:foreground "#f0f0f0"
					   :weight bold)))))
       "\n"))

    (let ((rating (car (imdb-select 'rating :mid id))))
      (when rating
	(insert
	 (propertize (format "Rating %s/%s votes" (getf rating :rating)
			     (getf rating :votes)))
	 "\n")))

    (insert "\n")
    
    (dolist (person (cl-sort
		     (imdb-select 'principal :mid id) '<
		     :key (lambda (e)
			    (let ((job (getf e :category)))
			      (cond
			       ((equal job "director") 1)
			       ((equal job "actor") 2)
			       ((equal job "actress") 2)
			       ((equal job "writer") 4)
			       (t 5))))))
      (insert (propertize
	       (format
		"%s %s%s\n"
		(propertize
		 (getf (car (imdb-select 'person :pid (getf person :pid)))
		       :primary-name)
		 'face 'variable-pitch)
		(propertize
		 (format "(%s)" (getf person :category))
		 'face '(variable-pitch (:foreground "#c0c0c0")))
		(let ((characters (imdb-select 'principal-character
					       :mid id
					       :pid (getf person :pid))))
		  (if (not characters)
		      ""
		    (propertize
		     (concat
		      " "
		      (mapconcat
		       (lambda (e)
			 (format "%S" (getf e :character)))
		       characters ", "))))))
	       'id (getf person :pid))))
    (goto-char (point-min))))

(defun imdb-mode-display-person (id)
  (let ((inhibit-read-only t)
	(films (imdb-select-where
		"select movie.mid, primary_title, start_year, type, principal.category from movie inner join principal on movie.mid = principal.mid where pid = ?"
		id)))
    (erase-buffer)
    (setq imdb-mode-mode 'person
	  imdb-mode-search id)
    (setq films (cl-sort
		 (nreverse films) '<
		 :key (lambda (e)
			(or (getf e :start-year) most-positive-fixnum))))
    (setq films (imdb-mode-filter films))
    (dolist (film films)
      (unless (equal (getf film :type) "tvEpisode") 
	(insert (propertize
		 (format "%s %s%s%s%s%s\n"
			 (propertize (format "%s" (getf film :start-year))
				     'face 'variable-pitch)
			 (propertize " " 'display '(space :align-to 8))
			 (propertize (getf film :primary-title)
				     'face 'variable-pitch)
			 (if (equal (getf film :type) "movie")
			     ""
			   (propertize (format " (%s)" (getf film :type))
				       'face '(variable-pitch
					       (:foreground "#a0a0a0"))))
			 (propertize (format " (%s)" (getf film :category))
				     'face '(variable-pitch
					     (:foreground "#c0c0c0")))
			 (let ((directors
				(imdb-select-where "select primary_name from person inner join crew on crew.pid = person.pid where crew.category = 'director' and crew.mid = ?"
						   (getf film :mid))))
			   (if (not directors)
			       ""
			     (propertize
			      (concat " " (mapconcat (lambda (e)
						       (getf e :primary-name))
						     directors ", "))
			      'face '(variable-pitch
				      (:foreground "#80a080"))))))
		 'id (getf film :mid)))))
    (goto-char (point-min))))

(defun imdb-update-image (id)
  (url-retrieve
   (format "http://www.imdb.com/title/%s/" id)
   (lambda (status buffer)
     (goto-char (point-min))
     (when (search-forward "\n\n" nil t)
       (imdb-update-image-1
	(loop with dom = (libxml-parse-html-region (point) (point-max))
	      for image in (dom-by-tag dom 'img)
	      for src = (dom-attr image 'src)
	      when (and src (string-match "_AL_" src))
	      return (shr-expand-url
		      (dom-attr (dom-parent dom image) 'href)
		      "http://www.imdb.com/"))
	buffer))
     (kill-buffer (current-buffer)))
   (list (current-buffer))))

(defun imdb-update-image-1 (url buffer)
  (url-retrieve
   url
   (lambda (status buffer)
     (goto-char (point-min))
     (imdb-update-image-2 (imdb-extract-image-json) buffer)
     (kill-buffer (current-buffer)))
   (list buffer)))

(defun imdb-update-image-2 (json buffer)
  (let ((src (imdb-get-image-from-json json)))
    (when src
      (url-retrieve
       src
       (lambda (status buffer)
	 (goto-char (point-min))
	 (when (search-forward "\n\n" nil t)
	   (let ((data (buffer-substring (point) (point-max))))
	     (when (buffer-live-p buffer)
	       (with-current-buffer buffer
		 (save-excursion
		   (goto-char (point-min))
		   (let ((inhibit-read-only t))
		     (delete-region (point) (line-end-position))
		     (insert-image
		      (create-image data 'imagemagick t :height 400))))))))
	 (kill-buffer (current-buffer)))
       (list buffer)))))

(defun imdb-get-image-json (url)
  (with-current-buffer (url-retrieve-synchronously url)
    (goto-char (point-min))
    (prog1
	(imdb-extract-image-json)
      (kill-buffer (current-buffer)))))

(provide 'imdb-mode)

;;; imdb-mode.el ends here