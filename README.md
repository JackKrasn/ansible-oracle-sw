# ANSIBLE playbooks for ORACLE DB

Проект для оркестровки Oracle инстансов и хоумов. Автоматическое развертывание новых хоумов, установка патчей, настройка SQLNET файлов, генерация oratab.

Реализованы роли:
* **orasw-install**

  Автоматическое развертывание оракл хоумов.

* **oratab**     

  Генерация oratab.

* **sqlnet**

  Генерация sqlnet.ora, tnsnames.ora, ldap.ora, listener.ora

* **psu-apply**  

  Установка патчей.

* **limit_homes**

  Служебная роль для ограничения структур. Используется, чтобы обрабатывать только заданные хоумы.

* **get_ora_inventory**   

  Служебная роль. Используется для дискаваринга.

* **dbca_templates**

  Копирование файлов шаблонов в Oracle Homes версий 12.1.0.2 и 12.2.0.1.
  Сами шаблоны не размещены в git из-за большого размера. Необходимо создать симлинк или разместить файлы в ./roles/dbca_templates/files/{12.1.0.2,12.2.0.1} в зависимости от версии. 

## Getting Started
Краткое пояснение, как использовать.

### Prerequisites

На хосте с которого будет запускаться playbook должен быть установлен *ansible*

Для Fedora:
```
dnf install ansible
```

Должен быть настроен доступ по ssh по ключам  к хостам, на которых будет производиться настройка.

Для корректной работы роли psu-apply необходимо установить питоновскую библиотеку на хосте, на котором производится установка патчей ролью
[oracledb]:(https://gitbft.ftc.ru/krasnukhin/python-oracledb/tree/master/oracledb)

Определить *virtualenv*
```
. /u/dba/venv/python_dba/bin/activate
```

Поставить пакет из репозитория

```
pip install -i https://bs-nexus.ftc.ru/repository/pypi-dba-group/simple --trusted-host bs-nexus.ftc.ru oracledb
```


### Installing

Скачать проект с gitlab.

```
git clone git@gitbft.ftc.ru:krasnukhin/ansible-oracle-sw.git
```
### Deployment

Запустить playbook со всеми ролями только на указанном хосте(*host_name*). Хост должен быть указан в [*./inventory/hosts*](https://gitbft.ftc.ru/krasnukhin/ansible-oracle-sw/blob/master/inventory/hosts)
```
ansible-playbook -i inventory/hosts -l host_name install-si-sw-psu.yml
```

Если нужно переопределить значение переменных, то необходимо указать --extra-vars.
>-e, --extra-vars                                    
>    set additional variables as key=value or YAML/JSON, if filename prepend with @

Пример файла extra.yml
```yaml
---
apply_only_homepaths:
   - /u/app/oracle/product/12.1.0.2/dbhome_2

datapatch_execute: True
shutdown_db: True
install_only_version:
  - 12.1.0.2
```
**apply_only_homepaths** - список каталогов с oracle хоумами, к которым  необходимо применить роли. Не относится к установке хоума.

Используется в ролях:
- psu-apply

**datapacth_execute** - Запустить datapatch после установки патчей или нет. Допустимые значения True/False.

Используется в ролях:
- psu-apply

**shutdown_db** - останавливать БД при установке патчей или нет. Переменная используется для роли *psu-apply*

Используется в ролях:
- psu-apply

**install_only_version** -список версий которые необходимо установить.
Описание доступных для установки версий находится в файле
[./roles/orasw-install/vars/main.yml](https://gitbft.ftc.ru/krasnukhin/ansible-oracle-sw/blob/master/roles/orasw-install/vars/main.yml)

Используется в ролях:
- orasw-install


Пример установки rdbms версии Oracle 12.1.0.2

```
ansible-playbook -i inventory\hosts -l host_name -e @extra.yml install-si-sw-psu.yml
```

## Contributing

Я использую модель управления ветками Gitflow.
Коммиты в мастер ветку строго запрещены.
Если хотите добавить  новый фукционал или что-то пофиксить смотрите как устроен процесс в
[Gitflow](https://habr.com/post/106912/)


## Versioning

Я использую [Семантическое Версионирование 2.0.0](http://semver.org/lang/ru)

Доступные релизы [tags on this repository](https://gitbft.ftc.ru/krasnukhin/ansible-oracle-sw/tags).

## Authors

* **Evgeniy Krasnukhin (e.krasnukhin@cft.ru)**
